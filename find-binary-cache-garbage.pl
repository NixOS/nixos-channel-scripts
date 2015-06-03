#! /usr/bin/env nix-shell
#! nix-shell -i perl -p perl perlPackages.DBDSQLite perlPackages.NetAmazonS3

use strict;
use Nix::Manifest;
use Net::Amazon::S3;
use File::Basename;
use DateTime::Format::Strptime;

my $bucketName = "nix-cache";
my $maxAge = 180 * 24 * 60 * 60;

my $dateParser = DateTime::Format::Strptime->new(pattern => "%Y-%m-%dT%H:%M:%S");

# Read the manifests of live releases.
my $res = `find /data/releases/nixos /data/releases/nixpkgs -name MANIFEST`;
die if $? != 0;
my @manifests = split /\n/, $res;

my %narFiles;
my %patches;

foreach my $manifest (@manifests) {
    print STDERR "loading $manifest\n";
    open TMP, "<$manifest" or die;
    my $s = <TMP> or die;
    chomp $s;
    close TMP;
    if ($s ne "version {") {
        warn "skipping very old manifest (i.e., for Nix <= 0.7)\n";
        next;
    }
    if (readManifest($manifest, \%narFiles, \%patches) < 3) {
        warn "manifest `$manifest' is too old (i.e., for Nix <= 0.7)\n";
        next;
    }
}

print STDERR scalar(keys %narFiles), " live store paths found\n";

my %hashParts;
my %fileHashes;

foreach my $storePath (keys %narFiles) {
    my $hashPart = substr(basename($storePath), 0, 32);
    die "collision: $storePath vs $hashParts{$hashPart}\n"
        if defined $hashParts{$hashPart};
    $hashParts{$hashPart} = $storePath;

    print "$storePath\n" if defined $ENV{'SHOW_LIVE'};

    foreach my $file (@{$narFiles{$storePath}}) {
        die unless defined $file->{hash};
        $file->{hash} =~ /^sha256:(.*)$/ or die;
        my $hash = $1;
        die unless length $hash == 52;
        $fileHashes{$1} = $hash;
        print "  $hash -> $file->{url}\n" if defined $ENV{'SHOW_LIVE'};
    }
}

exit if defined $ENV{'SHOW_LIVE'};

# S3 setup.
my $aws_access_key_id = $ENV{'AWS_ACCESS_KEY_ID'} or die;
my $aws_secret_access_key = $ENV{'AWS_SECRET_ACCESS_KEY'} or die;

my $s3 = Net::Amazon::S3->new(
    { aws_access_key_id     => $aws_access_key_id,
      aws_secret_access_key => $aws_secret_access_key,
      retry                 => 1,
    });

# List the bucket and determine which files should be deleted.
my $marker;
my $nrFiles = 0;
my $totalSize = 0;
my $narinfos = 0;
my $narinfosSize = 0;
my $nars = 0;
my $narsSize = 0;
my @garbage;
my $garbageSize = 0;
my %alive;
my $youngGarbage = 0;
my $youngGarbageSize = 0;

my $n = 0;
while (1) {
    print STDERR "fetching from ", ($marker // "start"), "...\n";
    my $res = $s3->list_bucket({ bucket => $bucketName, marker => $marker });
    die "could not get contents of S3 bucket $bucketName\n" unless $res;
    $marker = $res->{next_marker};

    foreach my $key (@{$res->{keys}}) {
        my $fn = $key->{key};
        $marker = $fn if $fn gt $marker;
        $nrFiles++;
        $totalSize += $key->{size};
        #print "$fn\n";

        my $isGarbage = 0;

        if ($fn =~ /^(\w{32})\.narinfo$/) {
            $narinfos++;
            $narinfosSize += $key->{size};
            my $hashPart = $1;
            my $storePath = $hashParts{$hashPart};
            if (defined $storePath) {
                #print STDERR "EXISTS $fn -> $storePath\n";
            } else {
                $isGarbage = 1;
            }
        }
        elsif ($fn =~ /nar\/(\w{52})\.nar.*$/) {
            $nars++;
            $narsSize += $key->{size};
            my $hash = $1;
            #print STDERR "$hash\n";
            if (defined $fileHashes{$hash}) {
                #print STDERR "EXISTS $fn\n";
            } else {
                $isGarbage = 1;
            }
        }
        elsif ($fn eq "nix-cache-info") {
        }
        else {
            printf STDERR "unknown file %s (%d bytes, %s)\n", $fn, $key->{size}, $key->{last_modified};
            $isGarbage = 1;
        }

        if ($isGarbage) {
            my $dt = $dateParser->parse_datetime($key->{last_modified}) or die;
            if ($dt->epoch() >= time() - $maxAge) {
                $youngGarbage++;
                $youngGarbageSize += $key->{size};
                printf STDERR "young %s (%d bytes, %s)\n", $fn, $key->{size}, $key->{last_modified};
            } else {
                push @garbage, $fn;
                $garbageSize += $key->{size};
                printf STDERR "garbage %s (%d bytes, %s)\n", $fn, $key->{size}, $key->{last_modified};
            }
        } else {
            $alive{$fn} = 1;
            printf STDERR "alive %s (%d bytes, %s)\n", $fn, $key->{size}, $key->{last_modified};
        }
    }

    $n++;
    #last if $n >= 2;
    last unless $res->{is_truncated};
}

foreach my $storePath (keys %narFiles) {
    my $hashPart = substr(basename($storePath), 0, 32);
    if (!defined $alive{"$hashPart.narinfo"}) {
        print STDERR "missing: $storePath -> $hashPart.narinfo\n";
    }
    foreach my $file (@{$narFiles{$storePath}}) {
        die unless defined $file->{hash};
        $file->{hash} =~ /^sha256:(.*)$/ or die;
        my $hash = $1;
        if (!defined $alive{"nar/$hash.nar.bz2"} && !defined $alive{"nar/$hash.nar.xz"}) {
            print STDERR "missing: $storePath -> nar/$hash.nar.*\n";
        }
    }
}

printf STDERR "%s files in bucket (%.2f GiB), %s .narinfos (%.2f GiB), %s .nars (%.2f GiB), %s old garbage (%.2f GiB), %s young garbage (%.2f GiB)\n",
    $nrFiles, $totalSize / (1024.0 * 1024.0 * 1024.0),
    $narinfos, $narinfosSize / (1024.0 * 1024.0 * 1024.0),
    $nars, $narsSize / (1024.0 * 1024.0 * 1024.0),
    scalar(@garbage), $garbageSize / (1024.0 * 1024.0 * 1024.0),
    $youngGarbage, $youngGarbageSize / (1024.0 * 1024.0 * 1024.0);

print "$_\n" foreach @garbage;
