use strict;
use readmanifest;
use File::Basename;
use File::stat;
use File::Temp qw/tempfile/;
use Fcntl ':flock';

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

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;
die "$narPath doesn't exist\n" unless -d $narPath;
die "$patchesPath doesn't exist\n" unless -d $patchesPath;

open LOCK, ">$dstChannelPath/.lock" or die;
flock LOCK, LOCK_EX;

system("date");

# Read the old manifest, if available.
my %narFilesOld;
my %localPathsOld;
my %patchesOld;

readManifest("$dstChannelPath/MANIFEST", \%narFilesOld, \%localPathsOld, \%patchesOld)
    if -f "$dstChannelPath/MANIFEST";

my %knownURLs;
while (my ($storePath, $files) = each %narFilesOld) {
    $knownURLs{$_->{url}} = $_ foreach @{$files};
}

# Fetch the new manifest.
my ($fh, $tmpManifest) = tempfile(UNLINK => 1);
system("$curl '$srcChannelURL/MANIFEST' > $tmpManifest") == 0 or die;

# Read the manifest.
my %narFiles;
my %localPaths;
my %patches;

readManifest($tmpManifest, \%narFiles, \%localPaths, \%patches);

%localPaths = ();
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

# Write the new manifest.
writeManifest("$dstChannelPath/MANIFEST.tmp", \%narFiles, \%patches);

# Generate patches.
if (0 && -e "$dstChannelPath/MANIFEST.tmp") {
    system("perl -I /home/buildfarm/nix/scripts /home/buildfarm/nix/scripts/generate-patches.pl $narPath $patchesPath $patchesURL $dstChannelPath/MANIFEST $dstChannelPath/MANIFEST.tmp") == 0 or die;
}

rename("$dstChannelPath/MANIFEST.tmp", "$dstChannelPath/MANIFEST") or die;
rename("$dstChannelPath/MANIFEST.tmp.bz2", "$dstChannelPath/MANIFEST.bz2") or die;

# Mirror nixexprs.tar.bz2.
my $tmpFile = "$dstChannelPath/.tmp.$$.nixexprs.tar.bz2";
system("$curl '$nixexprsURL' > $tmpFile") == 0 or die "cannot download `$nixexprsURL'";
rename($tmpFile, "$dstChannelPath/nixexprs.tar.bz2") or die "cannot rename $tmpFile";

# Remove ".hash.*" files corresponding to NARs that have been removed.
#foreach my $fn (glob "$narPath/.hash.*") {
#    my $fn2 = $fn;
#    $fn2 =~ s/\.hash\.//;
#    if (! -e "$fn2") {
#	print STDERR "removing hash $fn\n";
#	unlink "$fn";
#    }
#}
