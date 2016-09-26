{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let

  # FIXME
  nix = builtins.storePath /nix/store/b554awsd9vssb936mb32icgpfbyifsai-nix-1.12pre1234_abcdef;
  #lib.overrideDerivation nixUnstable (orig: {
  #  src = /home/eelco/Dev/nix;
  #});

in

stdenv.mkDerivation {
  name = "nixos-channel-scripts";

  buildInputs = with perlPackages;
    [ nix sqlite makeWrapper perl FileSlurp LWP LWPProtocolHttps ListMoreUtils DBDSQLite NetAmazonS3 boehmgc ];

  buildCommand = ''
    mkdir -p $out/bin

    g++ -g ${./generate-programs-index.cc} -Wall -std=c++11 -o $out/bin/generate-programs-index \
      -I ${nix}/include/nix -lnixmain -lnixexpr -lnixformat -lsqlite3 -lgc

    cp ${./mirror-nixos-branch.pl} $out/bin/mirror-nixos-branch
    wrapProgram $out/bin/mirror-nixos-branch --set PERL5LIB $PERL5LIB --prefix PATH : ${wget}/bin:${git}/bin:${nix}/bin:${gnutar}/bin:${xz}/bin:$out/bin

    patchShebangs $out/bin
  '';

}
