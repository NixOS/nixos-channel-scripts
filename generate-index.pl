#! /run/current-system/sw/bin/perl -w

use strict;
use DBI;
use DBD::SQLite;
use File::Find;
use List::Util qw(all);
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
    primary key (name, system, package)
  );
EOF
$dbh->do(<<EOF);
  create table if not exists Libraries (
    name        text not null,
    system      text not null,
    package     text not null,
    primary key (name, system, package)
  );
EOF

my $insertProgram = $dbh->prepare("insert or replace into Programs(name, system, package) values (?, ?, ?)");
my $insertLibrary = $dbh->prepare("insert or replace into Libraries(name, system, package) values (?, ?, ?)");

$dbh->begin_work;

sub wanted_bin {
    my ($system, $pkgname) = @_;
    return sub {
        ! /^\..*\z/s
        && $insertProgram->execute($_, $system, $pkgname);
    }
}

sub wanted_lib {
    my ($system, $pkgname) = @_;
    return sub {
        /^.*\.so\z/si
        && $insertLibrary->execute($_, $system, $pkgname);
    }
}

sub process_dir {
    my ($system, $pkgname, $dir) = @_;
    File::Find::find({wanted => wanted_bin($system, $pkgname)}, "$dir/bin") if -d "$dir/bin";
    File::Find::find({wanted => wanted_lib($system, $pkgname)}, "$dir/lib") if -d "$dir/lib";
    File::Find::find({wanted => wanted_lib($system, $pkgname)}, "$dir/lib64") if -d "$dir/lib64";
}

for my $system ("x86_64-linux", "i686-linux") {
    print STDERR "indexing programs and libraries for $system...\n";

    my $out = `nix-env -f $nixExprs -qaP \\* --drv-path --out-path --argstr system $system`;
    die "cannot evaluate Nix expressions for $system" if $? != 0;

    my %packages;

    foreach my $line (split "\n", $out) {
	my ($attrName, $name, $drvPath, $outPath) = split ' ', $line;
	die unless $attrName && $name && $outPath;

	my @outPaths = map { s/^[a-z]+=//; $_ } (split ";", $outPath);

	next unless all { defined $narFiles{$_} } @outPaths;
	next unless all { -d $_ } @outPaths;

	# Prefer shorter attribute names.
	my $prev = $packages{$drvPath};
	next if defined $prev &&
	    (length($prev->{attrName}) < length($attrName) ||
	     (length($prev->{attrName}) == length($attrName) && $prev->{attrName} le $attrName));

	$packages{$drvPath} = { attrName => $attrName, outPaths => [@outPaths] };
    }

    foreach my $drvPath (keys %packages) {
	my $pkg = $packages{$drvPath};
	process_dir($system, $pkg->{attrName}, "$_")
	    foreach @{$pkg->{outPaths}};
    }
}

$dbh->commit;
