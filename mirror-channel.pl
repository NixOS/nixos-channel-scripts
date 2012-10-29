# This script mirrors a remote Nix channel in the local filesystem.
# It downloads the remote manifest, then any NAR files that are not
# already available in the target directory.

use strict;
use Nix::Manifest;
use Nix::GeneratePatches;
use File::Basename;
use File::stat;


if (scalar @ARGV < 4 || scalar @ARGV > 6) {
    print STDERR "Syntax: perl mirror-channel.pl <src-channel-url> <dst-channel-dir> <nar-dir> <nar-url> [<all-patches-manifest [<nix-exprs-url>]]\n";
    exit 1;
}

my $curl = "curl --location --no-progress-bar --show-error --fail";

my $srcChannelURL = $ARGV[0];
my $dstChannelPath = $ARGV[1];
my $narPath = $ARGV[2];
my $narURL = $ARGV[3];
my $allPatchesManifest = $ARGV[4] || "";
my $nixexprsURL = $ARGV[5] || "$srcChannelURL/nixexprs.tar.bz2";

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;
die "$narPath doesn't exist\n" unless -d $narPath;

my $manifestPath = "$dstChannelPath/MANIFEST";


# Fetch the manifest.
system("$curl '$srcChannelURL/MANIFEST' > $dstChannelPath/MANIFEST") == 0 or die;


# Mirror nixexprs.tar.bz2.
system("$curl '$nixexprsURL' > $dstChannelPath/nixexprs.tar.bz2") == 0 or die "cannot download `$nixexprsURL'";


# Advertise a binary cache.
open FILE, ">$dstChannelPath/binary-cache-url" or die;
print FILE "http://nixos.org/binary-cache/" or die;
close FILE or die;


# Read the manifest.
my (%narFiles, %patches);
readManifest("$dstChannelPath/MANIFEST", \%narFiles, \%patches);

%patches = (); # not supported yet

my $size = scalar (keys %narFiles);
print "$size store paths in manifest\n";


# Protect against Hydra problems that leave the channel empty.
die "cowardly refusing to mirror an empty channel" if $size == 0;


# Download every file that we don't already have, and update every URL
# to point to the mirror.  Also fill in the size and hash fields in
# the manifest in order to be compatible with Nix < 0.13.

while (my ($storePath, $files) = each %narFiles) {
    foreach my $file (@{$files}) {
        my $narHash = $file->{narHash};
        my $srcURL = $file->{url};
        my $dstName = $narHash;
        $dstName =~ s/:/_/; # `:' in filenames might cause problems
        my $dstFile = "$narPath/$dstName";
        my $dstURL = "$narURL/$dstName";
        
        $file->{url} = $dstURL;
	if (! -e $dstFile) {
            print "downloading $srcURL\n";
            my $dstFileTmp = "$narPath/.tmp.$$.nar.$dstName";
            system("$curl '$srcURL' > $dstFileTmp") == 0 or die "failed to download `$srcURL'";

            # Verify whether the downloaded file is a bzipped NAR file
            # that matches the NAR hash given in the manifest.
            my $hash = `bunzip2 < $dstFileTmp | nix-hash --type sha256 --flat /dev/stdin` or die;
            chomp $hash;
            die "hash mismatch in downloaded file `$srcURL'" if "sha256:$hash" ne $file->{narHash};

            rename($dstFileTmp, $dstFile) or die "cannot rename $dstFileTmp";
        }

	$file->{size} = stat($dstFile)->size or die "cannot get size of $dstFile";

	my $hashFile = "$narPath/.hash.$dstName";
	my $hash;
	if (-e $hashFile) {
	    open HASH, "<$hashFile" or die;
	    $hash = <HASH>;
	    close HASH;
	} else {
	    $hash = `nix-hash --flat --type sha256 --base32 '$dstFile'` or die;
	    chomp $hash;
	    open HASH, ">$hashFile" or die;
	    print HASH $hash;
	    close HASH;
	}
	$file->{hash} = "sha256:$hash";
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
