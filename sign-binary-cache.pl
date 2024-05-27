#! /usr/bin/env nix-shell
#! nix-shell -i perl -p perl perlPackages.NetAmazonS3 perlPackages.ForksSuper perlPackages.DBDSQLite nix.perl-bindings

use strict;
use Forks::Super 'bg_eval';
use List::MoreUtils qw(part);
use MIME::Base64;
use Net::Amazon::S3;
use Net::Amazon::S3::Authorization::Basic;
use Net::Amazon::S3::Vendor::Generic;
use Nix::Manifest;
use Nix::Store;
use Nix::Utils;

my $bucketName = "nix-cache";
my $nrProcesses = 16;
my $secretKeyFile = "/home/eelco/Misc/Keys/cache.nixos.org-1/secret";

my $s = readFile $secretKeyFile;
chomp $s;
my ($keyName, $secretKey) = split ":", $s;
die "invalid secret key file ‘$secretKeyFile’\n" unless defined $keyName && defined $secretKey;
$secretKey = $s;	# API now wants whole key including name

my @files;
while (<>) {
    chomp;
    push @files, $_;
}

# S3 setup.
my $aws_access_key_id = $ENV{'AWS_ACCESS_KEY_ID'} or die;
my $aws_secret_access_key = $ENV{'AWS_SECRET_ACCESS_KEY'} or die;

my $s3 = Net::Amazon::S3->new(
    {
      retry                 => 1,
      authorization_context => Net::Amazon::S3::Authorization::Basic->new (
        aws_access_key_id     => $aws_access_key_id,
        aws_secret_access_key => $aws_secret_access_key,
        ),
      vendor => Net::Amazon::S3::Vendor::Generic->new (
        host => "local-cache.lan:3900",
        use_https => 0,
        use_virtual_host => 0,
        default_region => "garage",
        authorization_method => 'Net::Amazon::S3::Signature::V4',
        )
    });

my $bucket = $s3->bucket($bucketName) or die;

# Process .narinfos.
sub signNarInfo {
    my ($fn) = @_;

    die unless $fn =~ /\.narinfo$/;

    my $get = $bucket->get_key($fn, "GET");
    die "failed to get $fn\n"  unless defined $get;

    my $contents = $get->{value};

    $contents =~ /^StorePath: (\S+)$/m;
    die "corrupt NAR info $fn" unless defined $1;
    my $storePath = $1;

    if ($contents =~ /^Sig:/m) {
        print STDERR "skipping already signed $fn\n";
        return;
    }

    print STDERR "signing $fn...\n";

    my $narInfo = parseNARInfo($storePath, $contents);
    die "failed to parse NAR info of $fn\n" unless $narInfo;

    # Legacy: convert base16 to base32.
    my $narHash = $narInfo->{narHash};
    if (length $narHash != 59) {
        $narHash = `nix-hash --type sha256 --to-base32 ${\(substr($narHash, 7))}`;
        chomp $narHash;
        $narHash = "sha256:$narHash";
    }

    #print STDERR "$storePath -> $narInfo->{narHash} $narHash $narInfo->{narSize}\n";

    my $refs = [ map { "$Nix::Config::storeDir/$_" } @{$narInfo->{refs}} ];
    my $fingerprint = fingerprintPath($storePath, $narHash, $narInfo->{narSize}, $refs);
    #print STDERR "FP = $fingerprint\n";
    my $sig = signString($secretKey, $fingerprint);
    $contents .= "Sig: $sig\n";

    $bucket->add_key($fn, $contents) or die "failed to upload $fn\n";
}

# Fork processes to sign files in parallel.
my $i = 0;
my @filesPerProcess = part { $i++ % $nrProcesses } @files;
my @res;
for (my $n = 0; $n < $nrProcesses; $n++) {
    push @res, bg_eval {
        foreach my $fn (@{$filesPerProcess[$n]}) {
            eval {
                signNarInfo($fn);
            };
            warn "$@" if $@;
        }
        return 0;
    };
}

foreach my $res (@res) { if ($res) { } }
print STDERR "DONE\n";
