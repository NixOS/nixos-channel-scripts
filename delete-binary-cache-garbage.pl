#! /usr/bin/env nix-shell
#! nix-shell -i perl -p perl perlPackages.NetAmazonS3 perlPackages.ForksSuper

use strict;
use Net::Amazon::S3;
use Forks::Super 'bg_eval';
use List::MoreUtils qw(part);

my $bucketName = "nix-cache";
my $nrProcesses = 8;

my @files;
while (<>) {
    chomp;
    push @files, $_;
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

sub deleteFile {
    my ($fn) = @_;
    print STDERR "deleting $fn...\n";
    if (!$bucket->delete_key($fn)) {
        print STDERR "warning: failed to delete $fn\n";
    }
}

# Fork processes to delete files in parallel.
my $i = 0;
my @filesPerProcess = part { $i++ % $nrProcesses } @files;
my @res;
for (my $n = 0; $n < $nrProcesses; $n++) {
    push @res, bg_eval { deleteFile($_) foreach @{$filesPerProcess[$n]}; return 0; };
}

foreach my $res (@res) { if ($res) { } }
print STDERR "DONE\n";
