#! /var/run/current-system/sw/bin/perl -w

use strict;
use Nix::Manifest;
use File::Basename;

my $cacheDir = "/data/releases/binary-cache";

if (! -e "$cacheDir/nix-cache-info") {
    open FILE, ">$cacheDir/nix-cache-info" or die;
    print FILE "StoreDir: /nix/store\n";
    print FILE "WantMassQuery: 1\n";
    close FILE;
}

my @manifests = split " ", `find /data/releases/{nixos,nixpkgs,nix,patchelf} -name MANIFEST | grep -v '.tmp' | sort`;
die if $? != 0;
#my @manifests = ("/data/releases/nixpkgs/nixpkgs-0.5/MANIFEST");
#my @manifests = ("/data/releases/nixpkgs/nixpkgs-1.0pre19955_f823b62/MANIFEST");

foreach my $manifest (@manifests) {
    my %narFiles;
    my %patches;
    if (readManifest($manifest, \%narFiles, \%patches, 1) < 3) {
	print STDERR "warning: skipping old manifest $manifest\n";
	next;
    }
    print STDERR "processing $manifest (", scalar(keys(%narFiles)), " paths)...\n";

    while (my ($storePath, $nars) = each %narFiles) {
	my $pathHash = substr(basename($storePath), 0, 32);
	my $dst = "$cacheDir/$pathHash.narinfo";

	foreach my $nar (@{$nars}) {
	    if (! -e $dst) {
		print STDERR "  $storePath\n";
		#print STDERR "    $nar->{url} -> $dst\n";

		my $fileName = "/data/releases/nars/" . basename $nar->{url};
		if (! -e $fileName) {
		    warn "NAR not found: $fileName\n";
		    next;
		}

		my $narHash = $nar->{narHash};
		die unless defined $narHash;
		if (length($narHash) != 59) {
		    $narHash =~ s/.*://;
		    my $s = `nix-hash --type sha256 --to-base32 $narHash`;
		    die if $? != 0;
		    chomp $s;
		    $narHash = "sha256:$s";
		}
		die unless defined $nar->{size};
		die unless length($nar->{hash} || "") == 59;

		$nar->{hash} =~ /^sha256:(.*)$/ or die;
		my $fileHash = $1;

		my $link = "$cacheDir/nar/$fileHash.nar.bz2";
		if (! -e $link) {
		    link $fileName, $link
			or die "creating link: $!";
		}

		my $narSize = $nar->{narSize};
		unless (defined $narSize) {
		    $narSize = `bzip2 -d < $link | wc -c`;
		    chomp $narSize;
		    die unless $narSize =~ /^[0-9]+$/;
		}

		my $info;
		$info .= "StorePath: $storePath\n";
		$info .= "URL: nar/$fileHash.nar.bz2\n";
		$info .= "Compression: bzip2\n";
		$info .= "FileHash: $nar->{hash}\n";
		$info .= "FileSize: $nar->{size}\n";
		$info .= "NarHash: $narHash\n";
		$info .= "NarSize: $narSize\n";
		$info .= "References: " . join(" ", map { basename $_ } (split " ", $nar->{references})) . "\n";
		$info .= "Deriver: " . basename $nar->{deriver} . "\n" if $nar->{deriver} ne "";
		$info .= "System: $nar->{system}\n" if defined $nar->{system};

		my $tmp = "$cacheDir/.tmp.$$.$pathHash.narinfo";
		open INFO, ">$tmp" or die;
		print INFO "$info" or die;
		close INFO or die;
		rename($tmp, $dst) or die "cannot rename $tmp to $dst: $!\n";
	    }
	}
    }

}
