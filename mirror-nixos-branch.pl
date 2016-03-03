#! /run/current-system/sw/bin/perl -w

use strict;
use Data::Dumper;
use Fcntl qw(:flock);
use File::Basename;
use File::Path;
use File::Slurp;
use JSON::PP;
use LWP::UserAgent;
use List::MoreUtils qw(uniq);

my $branch = $ARGV[0];
my $jobset = $ARGV[1];

die "Usage: $0 BRANCH-NAME JOBSET_NAME\n" unless defined $branch && defined $jobset;

my $releaseUrl = "https://hydra.nixos.org/job/nixos/$jobset/tested/latest-finished";
my $releasesDir = "/data/releases/nixos/$branch";
my $channelsDir = "/data/releases/channels";
my $channelName = "nixos-$branch";

$ENV{'GIT_DIR'} = "/home/hydra-mirror/nixpkgs-channels";

sub fetch {
    my ($url, $type) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->default_header('Accept', $type) if defined $type;

    my $response = $ua->get($url);
    die "could not download $url: ", $response->status_line, "\n" unless $response->is_success;

    return $response->decoded_content;
}

my $releaseInfo = decode_json(fetch($releaseUrl, 'application/json'));

my $releaseId = $releaseInfo->{id} or die;
my $releaseName = $releaseInfo->{nixname} or die;
my $evalId = $releaseInfo->{jobsetevals}->[0] or die;
my $evalUrl = "https://hydra.nixos.org/eval/$evalId";
my $releaseDir = "$releasesDir/$releaseName";

my $evalInfo = decode_json(fetch($evalUrl, 'application/json'));

my $rev = $evalInfo->{jobsetevalinputs}->{nixpkgs}->{revision} or die;

print STDERR "release is ‘$releaseName’ (build $releaseId), eval is $evalId, dir is ‘$releaseDir’, Git commit is $rev\n";

# Guard against the channel going back in time.
my $curRelease = basename(readlink "$channelsDir/$channelName");
if (defined $curRelease) {
    my $d = `nix-instantiate --eval -E "builtins.compareVersions (builtins.parseDrvName \\"$curRelease\\").version (builtins.parseDrvName \\"$releaseName\\").version"`;
    chomp $d;
    die "channel would go back in time from $curRelease to $releaseName, bailing out\n" if $d == 1;
}

if (-d $releaseDir) {
    print STDERR "release already exists\n";
} else {
    my $tmpDir = dirname($releaseDir) . "/$releaseName-tmp";
    File::Path::make_path($tmpDir);

    write_file("$tmpDir/src-url", $evalUrl);
    write_file("$tmpDir/git-revision", $rev);
    write_file("$tmpDir/binary-cache-url", "https://cache.nixos.org");

    if (! -e "$tmpDir/store-paths.xz") {
        my $storePaths = decode_json(fetch("$evalUrl/store-paths", 'application/json'));
        write_file("$tmpDir/store-paths", join("\n", uniq(@{$storePaths})) . "\n");
        system("xz", "$tmpDir/store-paths") == 0 or die;
    }

    # Copy the manual.
    if (! -e "$tmpDir/manual") {
        my $manualInfo = decode_json(fetch("$evalUrl/job/nixos.manual.x86_64-linux", 'application/json'));
        my $manualPath = $manualInfo->{buildoutputs}->{out}->{path} or die;
        system("nix-store", "-r", $manualPath) == 0 or die "unable to fetch $manualPath\n";
        system("cp", "-rd", "$manualPath/share/doc/nixos", "$tmpDir/manual") == 0 or die "unable to copy manual from $manualPath";
    }

    sub downloadFile {
        my ($jobName, $dstName) = @_;

        my $buildInfo = decode_json(fetch("$evalUrl/job/$jobName", 'application/json'));

        my $srcFile = $buildInfo->{buildproducts}->{1}->{path} or die;
        $dstName //= basename($srcFile);
        my $dstFile = "$tmpDir/" . $dstName;

        if (! -e $dstFile) {
            print STDERR "downloading $srcFile to $dstFile...\n";
            system("NIX_REMOTE=https://cache.nixos.org/ nix cat-store '$srcFile' > '$dstFile.tmp'") == 0
                or die "unable to fetch $srcFile\n";
            rename("$dstFile.tmp", $dstFile) or die;
        }

        my $sha256_expected = $buildInfo->{buildproducts}->{1}->{sha256hash} or die;
        my $sha256_actual = `nix hash-file --type sha256 '$dstFile'`;
        chomp $sha256_actual;
        if ($sha256_expected ne $sha256_actual) {
            print STDERR "file $dstFile is corrupt\n";
            exit 1;
        }

        write_file("$dstFile.sha256", $sha256_expected);
    }

    downloadFile("nixos.channel", "nixexprs.tar.xz");
    downloadFile("nixos.iso_minimal.x86_64-linux");

    if ($branch !~ /-small/) {
        downloadFile("nixos.iso_minimal.i686-linux");
        downloadFile("nixos.iso_graphical.x86_64-linux");
        downloadFile("nixos.iso_graphical.i686-linux");
        downloadFile("nixos.ova.x86_64-linux");
        downloadFile("nixos.ova.i686-linux");
    }

    # Make "github-link" a redirect to the GitHub history of this
    # release.
    write_file("$tmpDir/.htaccess",
               "Redirect /releases/nixos/$branch/$releaseName/github-link https://github.com/NixOS/nixpkgs-channels/commits/$rev\n");
    write_file("$tmpDir/github-link", "");

    # FIXME: Generate the programs.sqlite database and put it in nixexprs.tar.xz.

    rename($tmpDir, $releaseDir) or die;
}

# Prevent concurrent writes to the channels and the Git clone.
open(my $lockfile, ">>", "$channelsDir/.htaccess.lock");
flock($lockfile, LOCK_EX) or die "cannot acquire channels lock\n";

# Update the channel.
my $htaccess = "$channelsDir/.htaccess-$channelName";
write_file($htaccess,
           "Redirect /channels/$channelName /releases/nixos/$branch/$releaseName\n" .
           "Redirect /releases/nixos/channels/$channelName /releases/nixos/$branch/$releaseName\n");

my $channelLink = "$channelsDir/$channelName";
unlink("$channelLink.tmp");
symlink($releaseDir, "$channelLink.tmp") or die;
rename("$channelLink.tmp", $channelLink) or die;

system("cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess") == 0 or die;

# Update the nixpkgs-channels repo.
system("git remote update origin >&2") == 0 or die;
system("git push channels $rev:refs/heads/$channelName >&2") == 0 or die;

print "$releaseDir\n";
