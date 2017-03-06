#! /usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use Digest::SHA;
use HTTP::Request;
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
my $channelsDir = "/data/releases/channels";
my $filesCache = "/data/releases/nixos-files.sqlite";
my $bucketName = "nix-releases";

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

my $bucket = $s3->bucket($bucketName) or die;


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
my $curReleaseDir = readlink "$channelsDir/$channelName";
if (defined $curReleaseDir) {
    my $curRelease = basename($curReleaseDir);
    my $d = `NIX_PATH= nix-instantiate --eval -E "builtins.compareVersions (builtins.parseDrvName \\"$curRelease\\").version (builtins.parseDrvName \\"$releaseName\\").version"`;
    chomp $d;
    die "channel would go back in time from $curRelease to $releaseName, bailing out\n" if $d == 1;
}

# Update the nixpkgs-channels repo.
open(my $lockfile, ">>", "$channelsDir/.htaccess.lock");
flock($lockfile, LOCK_EX) or die "cannot acquire channels lock\n";

system("git remote update origin >&2") == 0 or die;
system("git push channels $rev:refs/heads/$channelName >&2") == 0 or die;

flock($lockfile, LOCK_UN) or die "cannot release channels lock\n";

sub github_post {
    my ($url, $content) = @_;
    my $token = $ENV{'GITHUB_OAUTH_TOKEN'} or die "set GITHUB_OAUTH_TOKEN to an API token with repo_deployment privileges";

    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new('POST', $url);
    $req->header('Accept' => 'application/json');
    $req->header('Content-Type' => 'application/json');
    $req->header('Authorization' => "token $token");
    $req->content(encode_json($content));

    my $res = $ua->request($req);

    die "could not post to GitHub $url: ", $res->status_line, "\n" unless $res->is_success;

    return decode_json($res->decoded_content);
}

if ($bucket->head_key("$releasePrefix")) {
    print STDERR "release already exists\n";
} else {
    my $deploy_resp = github_post("https://api.github.com/repos/NixOS/nixpkgs/deployments",
                                  {
                                      'ref' => $rev,
                                      'required_contexts' => [],
                                      'auto_merge' => \0,
                                      'environment' => $channel_name
                                  }
        );
    github_post($deploy_resp->{statuses_url},
                {
                    'state' => 'success'
                }
        );

    my $tmpDir = "/data/releases/tmp/release-$channelName/$releaseName";
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

        my $srcFile = $buildInfo->{buildproducts}->{1}->{path} or die;
        $dstName //= basename($srcFile);
        my $dstFile = "$tmpDir/" . $dstName;

        my $sha256_expected = $buildInfo->{buildproducts}->{1}->{sha256hash} or die;

        if (! -e $dstFile) {
            print STDERR "downloading $srcFile to $dstFile...\n";
            write_file("$dstFile.sha256", $sha256_expected);
            system("NIX_REMOTE=https://cache.nixos.org/ nix cat-store '$srcFile' > '$dstFile.tmp'") == 0
                or die "unable to fetch $srcFile\n";
            rename("$dstFile.tmp", $dstFile) or die;
        }

        if (-e "$dstFile.sha256") {
            my $sha256_actual = `nix hash-file --type sha256 '$dstFile'`;
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
            downloadFile("nixos.iso_graphical.x86_64-linux");
            #downloadFile("nixos.iso_graphical.i686-linux");
            downloadFile("nixos.ova.x86_64-linux");
            #downloadFile("nixos.ova.i686-linux");
        }

    } else {
        downloadFile("tarball", "nixexprs.tar.xz");
    }

    # Generate the programs.sqlite database and put it in nixexprs.tar.xz.
    if ($channelName =~ /nixos/ && -e "$tmpDir/store-paths") {
        File::Path::make_path("$tmpDir/unpack");
        system("tar", "xfJ", "$tmpDir/nixexprs.tar.xz", "-C", "$tmpDir/unpack") == 0 or die;
        my $exprDir = glob("$tmpDir/unpack/*");
        system("generate-programs-index $filesCache $exprDir/programs.sqlite http://nix-cache.s3.amazonaws.com/ $tmpDir/store-paths $exprDir/nixpkgs") == 0 or die;
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
    $html .= "<table><thead><tr><th>File name</th><th>Size</th><th>SHA-512 hash</th></tr></thead><tbody>";

    # Upload the release to S3.
    for my $fn (sort glob("$tmpDir/*")) {
        my $basename = basename $fn;
        my $key = "$releasePrefix/" . $basename;

        unless (defined $bucket->head_key($key)) {
            print STDERR "mirroring $fn to s3://$bucketName/$key...\n";
            $bucket->add_key_filename(
                $key, $fn,
                { content_type => $fn =~ /.sha256|src-url|binary-cache-url|git-revision/ ? "text/plain" : "application/octet-stream" })
                or die $bucket->err . ": " . $bucket->errstr;
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

    $bucket->add_key($releasePrefix, $html,
                     { content_type => "text/html" })
        or die $bucket->err . ": " . $bucket->errstr;

    File::Path::remove_tree($tmpDir);
}

# Prevent concurrent writes to the channels directory.
flock($lockfile, LOCK_EX) or die "cannot acquire channels lock\n";

# Update the channel.
my $htaccess = "$channelsDir/.htaccess-$channelName";
my $target = "https://d3g5gsiof5omrk.cloudfront.net/$releasePrefix";
write_file($htaccess,
           "Redirect /channels/$channelName $target\n" .
           "Redirect /releases/nixos/channels/$channelName $target\n");

my $channelLink = "$channelsDir/$channelName";
if ((read_file($channelLink, err_mode => 'quiet') // "") ne $target) {
    write_file("$channelLink.tmp", "$target");
    rename("$channelLink.tmp", $channelLink) or die;
}

system("cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess.tmp") == 0 or die;
rename("$channelsDir/.htaccess.tmp", "$channelsDir/.htaccess") or die;
