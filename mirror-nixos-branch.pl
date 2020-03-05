#! /usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use Digest::SHA;
use Fcntl qw(:flock);
use File::Basename;
use File::Path;
use File::Slurp;
use File::stat;
use JSON::PP;
use LWP::UserAgent;
use List::MoreUtils qw(uniq);
use Net::Amazon::S3;
use POSIX qw(strftime);

my $channelName = $ARGV[0];
my $releaseUrl = $ARGV[1];

die "Usage: $0 CHANNEL-NAME RELEASE-URL\n" unless defined $channelName && defined $releaseUrl;

$channelName =~ /^([a-z]+)-(.*)$/ or die;
my $channelDirRel = $channelName eq "nixpkgs-unstable" ? "nixpkgs" : "$1/$2";


# Configuration.
my $TMPDIR = $ENV{'TMPDIR'} // "/tmp";
my $filesCache = "${TMPDIR}/nixos-files.sqlite";
my $bucketReleasesName = "nix-releases";
my $bucketChannelsName = "nix-channels";

$ENV{'GIT_DIR'} = "/home/hydra-mirror/nixpkgs-channels";


# S3 setup.
my $aws_access_key_id = $ENV{'AWS_ACCESS_KEY_ID'} or die;
my $aws_secret_access_key = $ENV{'AWS_SECRET_ACCESS_KEY'} or die;

my $s3 = Net::Amazon::S3->new(
    { aws_access_key_id     => $aws_access_key_id,
      aws_secret_access_key => $aws_secret_access_key,
      retry                 => 1,
      host                  => "s3-eu-west-1.amazonaws.com",
    });

my $bucketReleases = $s3->bucket($bucketReleasesName) or die;
my $bucketChannels = $s3->bucket($bucketChannelsName) or die;


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
my $evalInfo = decode_json(fetch($evalUrl, 'application/json'));
my $releasePrefix = "$channelDirRel/$releaseName";

my $rev = $evalInfo->{jobsetevalinputs}->{nixpkgs}->{revision} or die;

print STDERR "release is ‘$releaseName’ (build $releaseId), eval is $evalId, prefix is $releasePrefix, Git commit is $rev\n";

# Guard against the channel going back in time.
my $curRelease = $bucketChannels.get_key($channelName) or "";
$! = 0; # Clear errno to avoid reporting non-fork/exec-related issues
my $d = `NIX_PATH= nix-instantiate --eval -E "builtins.compareVersions (builtins.parseDrvName \\"$curRelease\\").version (builtins.parseDrvName \\"$releaseName\\").version"`;
if ($? != 0) {
    warn "Could not execute nix-instantiate: exit $?; errno $!\n";
    exit 1;
}
chomp $d;
if ($d == 1) {
    warn("channel would go back in time from $curRelease to $releaseName, bailing out\n");
    exit;
}

exit if $d == 0;

if ($bucketReleases->head_key("$releasePrefix")) {
    print STDERR "release already exists\n";
} else {
    my $tmpDir = "$TMPDIR/release-$channelName/$releaseName";
    File::Path::make_path($tmpDir);

    write_file("$tmpDir/src-url", $evalUrl);
    write_file("$tmpDir/git-revision", $rev);
    write_file("$tmpDir/binary-cache-url", "https://cache.nixos.org");

    if (! -e "$tmpDir/store-paths.xz") {
        my $storePaths = decode_json(fetch("$evalUrl/store-paths", 'application/json'));
        write_file("$tmpDir/store-paths", join("\n", uniq(@{$storePaths})) . "\n");
    }

    sub downloadFile {
        my ($jobName, $dstName) = @_;

        my $buildInfo = decode_json(fetch("$evalUrl/job/$jobName", 'application/json'));

        my $srcFile = $buildInfo->{buildproducts}->{1}->{path} or die "job '$jobName' lacks a store path";
        $dstName //= basename($srcFile);
        my $dstFile = "$tmpDir/" . $dstName;

        my $sha256_expected = $buildInfo->{buildproducts}->{1}->{sha256hash} or die;

        if (! -e $dstFile) {
            print STDERR "downloading $srcFile to $dstFile...\n";
            write_file("$dstFile.sha256", "$sha256_expected  $dstName");
            system("NIX_REMOTE=https://cache.nixos.org/ nix cat-store '$srcFile' > '$dstFile.tmp'") == 0
                or die "unable to fetch $srcFile\n";
            rename("$dstFile.tmp", $dstFile) or die;
        }

        if (-e "$dstFile.sha256") {
            my $sha256_actual = `nix hash-file --base16 --type sha256 '$dstFile'`;
            chomp $sha256_actual;
            if ($sha256_expected ne $sha256_actual) {
                print STDERR "file $dstFile is corrupt $sha256_expected $sha256_actual\n";
                exit 1;
            }
        }
    }

    if ($channelName =~ /nixos/) {
        downloadFile("nixos.channel", "nixexprs.tar.xz");
        downloadFile("nixos.iso_minimal.x86_64-linux");

        if ($channelName !~ /-small/) {
            downloadFile("nixos.iso_minimal.i686-linux");

            # Renamed iso_graphcial to iso_plasma5 in 20.03
            if ($releaseName !~ /-19./) {
                downloadFile("nixos.iso_plasma5.x86_64-linux");
            } else {
                downloadFile("nixos.iso_graphical.x86_64-linux");
            }

            downloadFile("nixos.ova.x86_64-linux");
            #downloadFile("nixos.ova.i686-linux");
        }

    } else {
        downloadFile("tarball", "nixexprs.tar.xz");
    }

    # Generate the programs.sqlite database and put it in
    # nixexprs.tar.xz. Also maintain the debug info repository at
    # https://cache.nixos.org/debuginfo.
    if ($channelName =~ /nixos/ && -e "$tmpDir/store-paths") {
        File::Path::make_path("$tmpDir/unpack");
        system("tar", "xfJ", "$tmpDir/nixexprs.tar.xz", "-C", "$tmpDir/unpack") == 0 or die;
        my $exprDir = glob("$tmpDir/unpack/*");
        system("generate-programs-index $filesCache $exprDir/programs.sqlite http://nix-cache.s3.amazonaws.com/ $tmpDir/store-paths $exprDir/nixpkgs") == 0 or die;
        system("index-debuginfo $filesCache s3://nix-cache $tmpDir/store-paths") == 0 or die;
        system("rm -f $tmpDir/nixexprs.tar.xz $exprDir/programs.sqlite-journal") == 0 or die;
        unlink("$tmpDir/nixexprs.tar.xz.sha256");
        system("tar", "cfJ", "$tmpDir/nixexprs.tar.xz", "-C", "$tmpDir/unpack", basename($exprDir)) == 0 or die;
        system("rm -rf $tmpDir/unpack") == 0 or die;
    }

    if (-e "$tmpDir/store-paths") {
        system("xz", "$tmpDir/store-paths") == 0 or die;
    }

    my $now = strftime("%F %T", localtime);
    my $title = "$channelName release $releaseName";
    my $githubLink = "https://github.com/NixOS/nixpkgs-channels/commits/$rev";

    my $html = "<html><head>";
    $html .= "<title>$title</title></head>";
    $html .= "<body><h1>$title</h1>";
    $html .= "<p>Released on $now from <a href='$githubLink'>Git commit <tt>$rev</tt></a> ";
    $html .= "via <a href='$evalUrl'>Hydra evaluation $evalId</a>.</p>";
    $html .= "<table><thead><tr><th>File name</th><th>Size</th><th>SHA-256 hash</th></tr></thead><tbody>";

    # Upload the release to S3.
    for my $fn (sort glob("$tmpDir/*")) {
        my $basename = basename $fn;
        my $key = "$releasePrefix/" . $basename;

        unless (defined $bucketReleases->head_key($key)) {
            print STDERR "mirroring $fn to s3://$bucketReleasesName/$key...\n";
            $bucketReleases->add_key_filename(
                $key, $fn,
                { content_type => $fn =~ /.sha256|src-url|binary-cache-url|git-revision/ ? "text/plain" : "application/octet-stream" })
                or die $bucketReleases->err . ": " . $bucketReleases->errstr;
        }

        next if $basename =~ /.sha256$/;

        my $size = stat($fn)->size;
        my $sha256 = Digest::SHA::sha256_hex(read_file($fn));
        $html .= "<tr>";
        $html .= "<td><a href='/$key'>$basename</a></td>";
        $html .= "<td align='right'>$size</td>";
        $html .= "<td><tt>$sha256</tt></td>";
        $html .= "</tr>";
    }

    $html .= "</tbody></table></body></html>";

    $bucketReleases->add_key($releasePrefix, $html,
                     { content_type => "text/html" })
        or die $bucketReleases->err . ": " . $bucketReleases->errstr;

    File::Path::remove_tree($tmpDir);
}

# Update the nixos-* branch in the nixpkgs repo. Also update the
# nixpkgs-channels repo for compatibility.
system("git remote update origin >&2") == 0 or die;
system("git push origin $rev:refs/heads/$channelName >&2") == 0 or die;
system("git push channels $rev:refs/heads/$channelName >&2") == 0 or die;

# Update channel on channels.nixos.org
$bucketChannels->add_key($channelsDir, $target, { "x-amz-website-redirect-location header" => $target });
