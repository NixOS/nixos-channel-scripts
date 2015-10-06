# This script mirrors a remote Nix channel in the local filesystem.
# It downloads the remote manifest, then any NAR files that are not
# already available in the target directory.

use strict;
use File::Basename;
use File::stat;
use Forks::Super 'bg_eval';
use List::MoreUtils qw(part);
use MIME::Base64;
use Net::Amazon::S3;
use Nix::Manifest;
use Nix::Store;
use Nix::Utils;


if (scalar @ARGV < 4 || scalar @ARGV > 6) {
    print STDERR "Syntax: perl mirror-channel.pl <src-channel-url> <dst-channel-dir> <bucket-name> <nar-url> [<nix-exprs-url>]\n";
    exit 1;
}

my $curl = "curl --location --silent --show-error --fail";

my $nrProcesses = 8;

my $srcChannelURL = $ARGV[0];
my $dstChannelPath = $ARGV[1];
my $bucketName = $ARGV[2];
my $cacheURL = $ARGV[3]; die if $cacheURL =~ /\/$/;
my $nixexprsURL = $ARGV[4];

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;

my $manifestPath = "$dstChannelPath/MANIFEST";


# Read the secret key for signing .narinfo files.
my $secretKeyFile = "/home/hydra-mirror/.keys/cache.nixos.org-1/secret"; # FIXME: make configurable
my ($keyName, $secretKey);
if (defined $secretKeyFile) {
    my $s = readFile $secretKeyFile;
    chomp $s;
    ($keyName, $secretKey) = split ":", $s;
    die "invalid secret key file ‘$secretKeyFile’\n" unless defined $keyName && defined $secretKey;
}


# S3 setup.
my $aws_access_key_id = $ENV{'AWS_ACCESS_KEY_ID'} or die;
my $aws_secret_access_key = $ENV{'AWS_SECRET_ACCESS_KEY'} or die;

my $s3 = Net::Amazon::S3->new(
    { aws_access_key_id     => $aws_access_key_id,
      aws_secret_access_key => $aws_secret_access_key,
      retry                 => 1,
    });

my $bucket = $s3->bucket($bucketName) or die;


# Fetch the manifest.
unless (-e "$dstChannelPath/MANIFEST") {
    system("$curl '$srcChannelURL/MANIFEST' > $dstChannelPath/MANIFEST") == 0 or die;
}


if (defined $nixexprsURL) {
    # Mirror nixexprs.tar.xz.
    system("$curl '$nixexprsURL' > $dstChannelPath/nixexprs.tar.xz") == 0 or die "cannot download `$nixexprsURL'";

    # Generate nixexprs.tar.bz2 for backwards compatibility.
    system("xz -d < $dstChannelPath/nixexprs.tar.xz | bzip2 > $dstChannelPath/nixexprs.tar.bz2") == 0 or die "cannot recompress nixexprs.tar";
}


# Advertise a binary cache.
open FILE, ">$dstChannelPath/binary-cache-url" or die;
print FILE $cacheURL or die;
close FILE or die;


# Read the manifest.
my (%narFiles, %patches);
readManifest("$dstChannelPath/MANIFEST", \%narFiles, \%patches);

%patches = (); # not supported yet

my $size = scalar (keys %narFiles);
print STDERR "$size store paths in manifest\n";


# Protect against Hydra problems that leave the channel empty.
die "cowardly refusing to mirror an empty channel" if $size == 0;


sub permute {
    my @list = @_;
    for (my $n = scalar @list - 1; $n > 0; $n--) {
        my $k = int(rand($n + 1)); # 0 <= $k <= $n 
        @list[$n, $k] = @list[$k, $n];
    }
    return @list;
}


# Download every file that we don't already have, and update every URL
# to point to the mirror.  Also fill in the size and hash fields in
# the manifest in order to be compatible with Nix < 0.13.

sub mirrorStorePath {
    my ($storePath, $res) = @_;
    my $nars = $narFiles{$storePath};
    die if scalar @{$nars} != 1;
    my $nar = $$nars[0];
    my $pathHash = substr(basename($storePath), 0, 32);
    my $narInfoFile = "$pathHash.narinfo";

    #print STDERR "$$: checking $narInfoFile\n";
    my $get = $bucket->get_key("$pathHash.narinfo", "GET");
    my $narInfo;

    if (defined $get) {
        $narInfo = parseNARInfo($storePath, $get->{value});

        #if (!defined $bucket->head_key("$narInfo->{url}", "GET")) {
        #    print STDERR "missing NAR $narInfo->{url}!\n"; 
        #    $bucket->delete_key("$pathHash.narinfo");
        #    goto recreate;
        #}

        $nar->{hash} = $narInfo->{fileHash};
        $nar->{size} = $narInfo->{fileSize};
        $nar->{narHash} = $narInfo->{narHash};
        $nar->{narSize} = $narInfo->{narSize};
        $nar->{compressionType} = $narInfo->{compression};
        $nar->{url} = "$cacheURL/$narInfo->{url}";

    } else {
      recreate:
        my $dstFileTmp = "/tmp/nar.$$";
        my $ext;

        if (isValidPath($storePath) && queryPathHash($storePath) eq $nar->{narHash}) {
            print STDERR "copying $storePath\n";

            # Verify that $storePath hasn't been corrupted and compress it at the same time.
            $ext = "xz";
            my $narHash = `bash -c 'exec 4>&1; nix-store --dump $storePath | tee >(nix-hash --type sha256 --base32 --flat /dev/stdin >&4) | xz -7 > $dstFileTmp'`;
            die "unable to compress $storePath to $dstFileTmp\n" if $? != 0;
            chomp $narHash;
            die "hash mismatch in `$storePath'" if "sha256:$narHash" ne $nar->{narHash};
        } else {
            print STDERR "downloading $nar->{url}\n";
            system("$curl '$nar->{url}' > $dstFileTmp") == 0 or die "failed to download `$nar->{url}'";

            # Verify whether the downloaded file is a bzipped NAR file
            # that matches the NAR hash given in the manifest.
            $ext = "bz2";
            my $narHash = `bunzip2 < $dstFileTmp | nix-hash --type sha256 --base32 --flat /dev/stdin` or die;
            chomp $narHash;
            die "hash mismatch in downloaded file `$nar->{url}'" if "sha256:$narHash" ne $nar->{narHash};
        }

        # Compute the hash of the compressed NAR (Hydra doesn't provide one).
        my $fileHash = hashFile("sha256", 1, $dstFileTmp);
        my $dstFile = "nar/$fileHash.nar.$ext";
        $nar->{url} = "$cacheURL/$dstFile";
        $nar->{hash} = "sha256:$fileHash";
        $nar->{size} = stat($dstFileTmp)->size;

        if (!defined $bucket->head_key($dstFile)) {
            print STDERR "uploading $dstFile ($nar->{size} bytes)\n";
            $bucket->add_key_filename($dstFile, $dstFileTmp) or die "failed to upload $dstFile to S3\n";
        }

        unlink($dstFileTmp) or die;

        # Write the .narinfo.
        my $info;
        my @refs = split " ", $nar->{references};
        $info .= "StorePath: $storePath\n";
        $info .= "URL: nar/$fileHash.nar.$ext\n";
        $info .= "Compression: " . ($ext eq "xz" ? "xz" : "bzip2") . "\n";
        $info .= "FileHash: $nar->{hash}\n";
        $info .= "FileSize: $nar->{size}\n";
        $info .= "NarHash: $nar->{narHash}\n";
        $info .= "NarSize: $nar->{narSize}\n";
        $info .= "References: " . join(" ", map { basename $_ } @refs) . "\n";
        $info .= "Deriver: " . basename $nar->{deriver} . "\n" if $nar->{deriver} ne "";
        $info .= "System: $nar->{system}\n" if defined $nar->{system};

        if (defined $keyName) {
            my $fingerprint = fingerprintPath($storePath, $nar->{narHash}, $nar->{narSize}, \@refs);
            my $sig = encode_base64(signString(decode_base64($secretKey), $fingerprint), "");
            $info .= "Sig: $keyName:$sig\n";
        }

        $bucket->add_key($narInfoFile, $info) or die "failed to upload $narInfoFile to S3\n";
    }

    $res->{$storePath} = $nar;
}


# Spawn a bunch of children to mirror paths in parallel.
my $i = 0;
my @filesPerProcess = part { $i++ % $nrProcesses } permute(keys %narFiles);
my @results;
for (my $n = 0; $n < $nrProcesses; $n++) {
    push @results, bg_eval { my $res = {}; mirrorStorePath($_, $res) foreach @{$filesPerProcess[$n]}; return $res; }
}


# Get the updated NAR info from the children so we can update the manifest.
foreach my $r (@results) {
    while (my ($storePath, $nar) = each %$r) {
        $narFiles{$storePath} = [$nar];
    }
}


# Make the temporary manifest available.
writeManifest("$dstChannelPath/MANIFEST", \%narFiles, \%patches);
