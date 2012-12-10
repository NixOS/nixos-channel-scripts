#! /var/run/current-system/sw/bin/perl -w -I .

use strict;
use Nix::Manifest;
use File::Basename;

my $cacheDir = "/data/releases/binary-cache";


# Read the manifests.
my %narFiles;
my %patches;

foreach my $manifest (@ARGV) {
    print STDERR "loading $manifest\n";
    if (readManifest($manifest, \%narFiles, \%patches, 1) < 3) {
        warn "manifest `$manifest' is too old (i.e., for Nix <= 0.7)\n";
    }
}


# Find the live archives.
my %usedFiles;
my %hashParts;

foreach my $storePath (keys %narFiles) {
    $storePath =~ /\/nix\/store\/([a-z0-9]+)/ or die "WRONG: $storePath";
    $hashParts{$1} = 1;
    foreach my $file (@{$narFiles{$storePath}}) {
        $file->{url} =~ /\/([^\/]+)$/;
        my $basename = $1;
        die unless defined $basename;
        #print STDERR "GOT $basename\n";
        $usedFiles{$basename} = 1;
	die "$storePath does not have a file hash" unless defined $file->{hash};
	if ($file->{hash} =~ /sha256:(.+)/) {
	    die unless length($1) == 52;
	    $usedFiles{"$1.nar.bz2"} = 1;
	}
        #print STDERR "missing archive `$basename'\n"
        #    unless defined $readcache::archives{$basename};
    }
}

foreach my $patch (keys %patches) {
    foreach my $file (@{$patches{$patch}}) {
        $file->{url} =~ /\/([^\/]+)$/;
        my $basename = $1;
        die unless defined $basename;
        #print STDERR "GOT2 $basename\n";
        $usedFiles{$basename} = 1;
        #die "missing archive `$basename'"
        #    unless defined $readcache::archives{$basename};
    }
}


sub checkDir {
    my ($dir) = @_;
    opendir(DIR, "$dir") or die "cannot open `$dir': $!";
    while (readdir DIR) {
        next unless $_ =~ /^sha256_/ || $_ =~ /\.nar-bsdiff$/ || $_ =~ /\.nar\.bz2$/;
	if (!defined $usedFiles{$_}) {
	    print "$dir/$_\n";
	} else {
	    #print STDERR "keeping $dir/$_\n";
	}

    }
    closedir DIR;
}

checkDir("/data/releases/nars");
checkDir("/data/releases/patches");
checkDir("$cacheDir/nar");

# Look for obsolete narinfo files.
opendir(DIR, $cacheDir) or die;
while (readdir DIR) {
    next unless /^(.*)\.narinfo$/;
    my $hashPart = $1;
    if (!defined $hashParts{$hashPart}) {
	print "$cacheDir/$_\n";
    } else {
	#print STDERR "keeping $cacheDir/$_\n";
    }
}
closedir DIR;
