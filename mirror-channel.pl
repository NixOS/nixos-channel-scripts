use strict;
use readmanifest;
use File::Basename;
use File::stat;
use File::Temp qw/tempfile/;

if (scalar @ARGV != 3 && scalar @ARGV != 4) {
    print STDERR "Syntax: perl mirror-channel.pl <src-channel-url> <dst-channel-url> <dst-channel-dir> [<nix-exprs-url>]\n";
    exit 1;
}

my $srcChannelURL = $ARGV[0];
my $dstChannelURL = $ARGV[1];
my $dstChannelPath = $ARGV[2];
my $nixexprsURL = $ARGV[3] || "$srcChannelURL/nixexprs.tar.bz2";

die "$dstChannelPath doesn't exist\n" unless -d $dstChannelPath;

my ($fh, $tmpManifest) = tempfile(UNLINK => 1);
system("curl --location --fail '$srcChannelURL/MANIFEST' > $tmpManifest") == 0 or die;

# Read the manifest.
my %narFiles;
my %localPaths;
my %patches;

my $version = readManifest($tmpManifest, \%narFiles, \%localPaths, \%patches);

%localPaths = ();
%patches = (); # not supported yet

my $size = scalar (keys %narFiles);
print "$size store paths in manifest\n";

# Download every file that we don't already have, and update every URL
# to point to the mirror.  Also fill in the size and hash fields in
# the manifest in order to be compatible with Nix < 0.13.

while (my ($storePath, $files) = each %narFiles) {
    foreach my $file (@{$files}) {
        my $srcURL = $file->{url};
        my $dstName = basename $srcURL;
        my $dstFile = "$dstChannelPath/$dstName";
        my $dstURL = "$dstChannelURL/$dstName";
        
        $file->{url} = $dstURL;
        if (! -e $dstFile) {
            print "downloading $srcURL\n";
            my $dstFileTmp = "$dstChannelPath/.tmp.$$.nar.$dstName";
            system("curl --location --fail '$srcURL' > $dstFileTmp") == 0 or die;
            rename($dstFileTmp, $dstFile) or die "cannot rename $dstFileTmp";
        }
        
        $file->{size} = stat($dstFile)->size or die;

        my $hashFile = "$dstChannelPath/.hash.$dstName";
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

# Write the new manifest.
writeManifest("$dstChannelPath/MANIFEST", \%narFiles, \%patches);

# Mirror nixexprs.tar.bz2.
my $tmpFile = "$dstChannelPath/.tmp.$$.nixexprs.tar.bz2";
system("curl --location --fail '$nixexprsURL' > $tmpFile") == 0 or die;
rename($tmpFile, "$dstChannelPath/nixexprs.tar.bz2") or die "cannot rename $tmpFile";
