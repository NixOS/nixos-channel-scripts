# This script mirrors a remote Nix channel in the local filesystem.
# It downloads the remote manifest, then any NAR files that are not
# already available in the target directory.

use strict;
use Nix::Manifest;
use Nix::GeneratePatches;
use Nix::Utils;
use File::Basename;
use File::stat;


if (scalar @ARGV < 4 || scalar @ARGV > 6) {
    print STDERR "Syntax: perl mirror-channel.pl <src-channel-url> <dst-channel-dir> <nar-dir> <nar-url> [<all-patches-manifest [<nix-exprs-url>]]\n";
    exit 1;
}

my $curl = "curl --location --silent --show-error --fail";

my $srcChannelURL = $ARGV[0];
my $dstChannelPath = $ARGV[1];
my $cacheDir = $ARGV[2];
my $cacheURL = $ARGV[3];
my $allPatchesManifest = $ARGV[4] || "";
my $nixexprsURL = $ARGV[5] || "$srcChannelURL/nixexprs.tar.xz";

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;
die "$cacheDir doesn't exist\n" unless -d $cacheDir;

my $manifestPath = "$dstChannelPath/MANIFEST";
my $narDir = "$cacheDir/nar";


# Fetch the manifest.
system("$curl '$srcChannelURL/MANIFEST' > $dstChannelPath/MANIFEST") == 0 or die;


# Mirror nixexprs.tar.xz.
system("$curl '$nixexprsURL' > $dstChannelPath/nixexprs.tar.xz") == 0 or die "cannot download `$nixexprsURL'";


# Generate nixexprs.tar.bz2 for backwards compatibility.
system("xz -d < $dstChannelPath/nixexprs.tar.xz | bzip2 > $dstChannelPath/nixexprs.tar.bz2") == 0 or die "cannot recompress nixexprs.tar";


# Advertise a binary cache.
open FILE, ">$dstChannelPath/binary-cache-url" or die;
print FILE "http://nixos.org/binary-cache/" or die;
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

foreach my $storePath (permute(keys %narFiles)) {
    my $nars = $narFiles{$storePath};

    my $pathHash = substr(basename($storePath), 0, 32);
    my $narInfoFile = "$cacheDir/$pathHash.narinfo";

    foreach my $nar (@{$nars}) {
        if (! -e $narInfoFile) {
            my $dstFileTmp = "$narDir/.tmp.$$.nar.$nar->{narHash}";
            print STDERR "downloading $nar->{url}\n";
            system("$curl '$nar->{url}' > $dstFileTmp") == 0 or die "failed to download `$nar->{url}'";
            
            # Verify whether the downloaded file is a bzipped NAR file
            # that matches the NAR hash given in the manifest.
            my $narHash = `bunzip2 < $dstFileTmp | nix-hash --type sha256 --flat /dev/stdin` or die;
            chomp $narHash;
            die "hash mismatch in downloaded file `$nar->{url}'" if "sha256:$narHash" ne $nar->{narHash};

            # Compute the hash of the compressed NAR (Hydra doesn't provide one).
            my $fileHash = `nix-hash --flat --type sha256 --base32 '$dstFileTmp'` or die;
            chomp $fileHash;
            $nar->{hash} = "sha256:$fileHash";

            my $dstFile = "$narDir/$fileHash.nar.bz2";
            if (-e $dstFile) {
                unlink($dstFileTmp) or die;
            } else {
                rename($dstFileTmp, $dstFile) or die "cannot rename $dstFileTmp to $dstFile";
            }

            $nar->{size} = stat($dstFile)->size;

            # Write the .narinfo.
            my $info;
            $info .= "StorePath: $storePath\n";
            $info .= "URL: nar/$fileHash.nar.bz2\n";
            $info .= "Compression: bzip2\n";
            $info .= "FileHash: $nar->{hash}\n";
            $info .= "FileSize: $nar->{size}\n";
            $info .= "NarHash: $nar->{narHash}\n";
            $info .= "NarSize: $nar->{narSize}\n";
            $info .= "References: " . join(" ", map { basename $_ } (split " ", $nar->{references})) . "\n";
            $info .= "Deriver: " . basename $nar->{deriver} . "\n" if $nar->{deriver} ne "";
            $info .= "System: $nar->{system}\n" if defined $nar->{system};

            my $tmp = "$cacheDir/.tmp.$$.$pathHash.narinfo";
            open INFO, ">$tmp" or die;
            print INFO "$info" or die;
            close INFO or die;
            rename($tmp, $narInfoFile) or die "cannot rename $tmp to $narInfoFile: $!\n";
        }

        my $narInfo = parseNARInfo($storePath, readFile($narInfoFile));
        $nar->{hash} = $narInfo->{fileHash};
        $nar->{size} = $narInfo->{fileSize};
        $nar->{narHash} = $narInfo->{narHash};
        $nar->{narSize} = $narInfo->{narSize};
        $nar->{url} = "$cacheURL/$narInfo->{url}";

	warn "archive `$cacheDir/$narInfo->{url}' has gone missing!\n" unless -f "$cacheDir/$narInfo->{url}";
    }
}


# Read all the old patches and propagate the useful ones.  We use the
# file "all-patches" to keep track of all patches that have been
# generated in the past, so that patches are not lost if (for
# instance) a package temporarily disappears from the source channel,
# or if multiple instances of this script are running concurrently.
my (%dummy, %allPatches);
readManifest($allPatchesManifest, \%dummy, \%allPatches)
    if $allPatchesManifest ne "" && -f $allPatchesManifest;
propagatePatches \%allPatches, \%narFiles, \%patches;


# Make the temporary manifest available.
writeManifest("$dstChannelPath/MANIFEST", \%narFiles, \%patches);
