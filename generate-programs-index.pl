#! /run/current-system/sw/bin/perl -w

use strict;
use DBI;
use DBD::SQLite;
use Nix::Manifest;

my $nixExprs = $ARGV[0] or die;
my $dbPath = $ARGV[1] or die;
my $manifestPath = $ARGV[2] or die;

my (%narFiles, %patches);
readManifest("$manifestPath", \%narFiles, \%patches);

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbPath", "", "")
    or die "cannot open database `$dbPath'";
$dbh->{RaiseError} = 1;
$dbh->{PrintError} = 0;

$dbh->do(<<EOF);
  create table if not exists Programs (
    name        text not null,
    system      text not null,
    package     text not null,
    attrPath    text not null,
    primary key (name, system, package, attrPath)
  );
EOF

my $insertProgram = $dbh->prepare("insert or replace into Programs(name, system, package, attrPath) values (?, ?, ?, ?)");

$dbh->begin_work;

sub process_dir {
    my ($system, $pkgname, $attrPath, $dir) = @_;
    return unless -d $dir;
    print STDERR "indexing $dir\n";
    opendir DH, "$dir" or die "opening $dir";
    for my $program (readdir DH) {
        next if substr($program, 0, 1) eq ".";
        $insertProgram->execute($program, $system, $pkgname, $attrPath);
    }
    closedir DH;
}

for my $system ("x86_64-linux", "i686-linux") {
    print STDERR "indexing programs for $system...\n";

    my $out = `nix-env -f $nixExprs -qaP \\* --out-path --argstr system $system`;
    die "cannot evaluate Nix expressions for $system" if $? != 0;

    foreach my $line (split "\n", $out) {
	my ($attrPath, $name, $outPath) = split ' ', $line;
	die unless $attrPath && $name && $outPath;
	next unless defined $narFiles{$outPath};
	next unless -d $outPath;
	my $pkgname = $name;
	$pkgname =~ s/-\d.*//;
	process_dir($system, $pkgname, $attrPath, "$outPath/bin");
	process_dir($system, $pkgname, $attrPath, "$outPath/sbin");
    }
}

$dbh->commit;
