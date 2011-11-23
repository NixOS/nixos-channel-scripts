# This script mirrors a remote Nix channel in the local filesystem.
# It downloads the remote manifest, then any NAR files that are not
# already available in the target directory.  If $ENABLE_PATCHES is
# set, it also generates patches between the NAR files in the old
# version of the manifest and the new version.  Because this script
# can take a long time to finish, it uses a lock to guard against
# concurrent updates, allowing it to be run periodically from a cron
# job.

use strict;
use Nix::Manifest;
use Nix::GeneratePatches;
use File::Basename;
use File::stat;
use File::Temp qw/tempfile tempdir/;
use Fcntl ':flock';
use POSIX qw(strftime);


if (scalar @ARGV != 6 && scalar @ARGV != 7) {
    print STDERR "Syntax: perl mirror-channel.pl <src-channel-url> <dst-channel-dir> <nar-dir> <nar-url> <patches-dir> <patches-url> [<nix-exprs-url>]\n";
    exit 1;
}

my $curl = "curl --location --silent --show-error --fail";

my $srcChannelURL = $ARGV[0];
my $dstChannelPath = $ARGV[1];
my $narPath = $ARGV[2];
my $narURL = $ARGV[3];
my $patchesPath = $ARGV[4];
my $patchesURL = $ARGV[5];
my $nixexprsURL = $ARGV[6] || "$srcChannelURL/nixexprs.tar.bz2";
my $enablePatches = defined $ENV{'ENABLE_PATCHES'} && -e "$dstChannelPath/MANIFEST";

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;
die "$narPath doesn't exist\n" unless -d $narPath;
die "$patchesPath doesn't exist\n" unless -d $patchesPath;

my $manifestPath = "$dstChannelPath/MANIFEST";

my $tmpDir = tempdir("nix-mirror-XXXXXXX", TMPDIR => 1, CLEANUP => 1);


open LOCK, ">$dstChannelPath/.lock" or die;
flock LOCK, LOCK_EX;

print STDERR "started mirroring at ", strftime("%a %b %e %H:%M:%S %Y", localtime), "\n";


# Backup the old manifest once per day.
my $backupPath = strftime("$dstChannelPath/MANIFEST.backup-%Y%m%d", gmtime);
if (-f $manifestPath && ! -f $backupPath) {
    system "cp $manifestPath $backupPath";
}


# Read the old manifest, if available.
my %narFilesOld;
my %patchesOld;

readManifest($manifestPath, \%narFilesOld, \%patchesOld)
    if -f $manifestPath;

my %knownURLs;
while (my ($storePath, $files) = each %narFilesOld) {
    $knownURLs{$_->{url}} = $_ foreach @{$files};
}


# Fetch the new manifest.
my $srcManifest = "$tmpDir/MANIFEST.src";
system("$curl '$srcChannelURL/MANIFEST' > $srcManifest") == 0 or die;


# Read the manifest.
my (%narFiles, %patches);
readManifest($srcManifest, \%narFiles, \%patches);

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
            system("bunzip2 < $dstFileTmp > $tmpDir/out") == 0 or die "downloaded file is not a bzip2 file!";
            my $hash = `nix-hash --type sha256 --flat $tmpDir/out`;
            chomp $hash;
            die "hash mismatch in downloaded file `$srcURL'" if "sha256:$hash" ne $file->{narHash};

            rename($dstFileTmp, $dstFile) or die "cannot rename $dstFileTmp";
        }

        my $old = $knownURLs{$dstURL};

        if (defined $old) {
            $file->{size} = $old->{size};
            $file->{hash} = $old->{hash};
        } else {
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
}


# Read all the old patches and propagate the useful ones.  We use the
# file "all-patches" to keep track of all patches that have been
# generated in the past, so that patches are not lost if (for
# instance) a package temporarily disappears from the source channel,
# or if multiple instances of this script are running concurrently.
my (%dummy1, %dummy2, %allPatches);

sub readAllPatches {
    readManifest("$patchesPath/all-patches", \%dummy1, \%dummy2, \%allPatches)
        if -f "$patchesPath/all-patches";
}

readAllPatches;

propagatePatches \%allPatches, \%narFiles, \%patches;
propagatePatches \%patchesOld, \%narFiles, \%patches; # not really needed


# Make the temporary manifest available.
writeManifest("$dstChannelPath/MANIFEST.tmp", \%narFiles, \%patches);

rename("$dstChannelPath/MANIFEST.tmp", "$manifestPath") or die;
rename("$dstChannelPath/MANIFEST.tmp.bz2", "$manifestPath.bz2") or die;


# Mirror nixexprs.tar.bz2.  This should really be done atomically with updating the manifest.
my $tmpFile = "$dstChannelPath/.tmp.$$.nixexprs.tar.bz2";
system("$curl '$nixexprsURL' > $tmpFile") == 0 or die "cannot download `$nixexprsURL'";
rename($tmpFile, "$dstChannelPath/nixexprs.tar.bz2") or die "cannot rename $tmpFile";


# Release the lock on the manifest to allow the manifest to be updated
# by other runs of this script while we're generating patches.
flock LOCK, LOCK_UN;


if ($enablePatches) {

    # Generate patches asynchronously.  This can take a long time.
    generatePatches(\%narFilesOld, \%narFiles, \%allPatches, \%patches,
        $narPath, $patchesPath, $patchesURL, $tmpDir);

    # Lock all-patches.
    open PLOCK, ">$patchesPath/all-patches.lock" or die;
    flock PLOCK, LOCK_EX;

    # Update the list of all patches.  We need to reread all-patches
    # and merge in our new patches because the file may have changed
    # in the meantime.
    readAllPatches;
    copyPatches \%patches, \%allPatches;
    writeManifest("$patchesPath/all-patches", {}, \%allPatches, 0);

    # Reacquire the manifest lock.
    flock LOCK, LOCK_EX;

    # Rewrite the manifest.  We have to reread it and propagate all
    # patches because it may have changed in the meantime.
    readManifest($manifestPath, \%narFiles, \%patches);

    propagatePatches \%allPatches, \%narFiles, \%patches;

    writeManifest($manifestPath, \%narFiles, \%patches);
}
