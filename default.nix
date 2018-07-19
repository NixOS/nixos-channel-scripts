{ pkgs ? import <nixpkgs> {} }:

with pkgs;

let

  nix = nixUnstable;
  #lib.overrideDerivation nixUnstable (orig: {
  #  src = /home/eelco/Dev/nix;
  #});

in

stdenv.mkDerivation {
  name = "nixos-channel-scripts";

  buildInputs = with perlPackages;
    [ pkgconfig nix sqlite makeWrapper perl FileSlurp LWP LWPProtocolHttps ListMoreUtils DBDSQLite NetAmazonS3 boehmgc nlohmann_json boost ];

  buildCommand = ''
    mkdir -p $out/bin

    cp ${./file-cache.hh} file-cache.hh

    g++ -Os -g ${./generate-programs-index.cc} -Wall -std=c++14 -o $out/bin/generate-programs-index -I . \
      $(pkg-config --cflags nix-main) \
      $(pkg-config --libs nix-main) \
      $(pkg-config --libs nix-expr) \
      $(pkg-config --libs nix-store) \
      -lsqlite3 -lgc

    g++ -Os -g ${./index-debuginfo.cc} -Wall -std=c++14 -o $out/bin/index-debuginfo -I . \
      $(pkg-config --cflags nix-main) \
      $(pkg-config --libs nix-main) \
      $(pkg-config --libs nix-store) \
      -lsqlite3

    cp ${./mirror-nixos-branch.pl} $out/bin/mirror-nixos-branch
    wrapProgram $out/bin/mirror-nixos-branch --set PERL5LIB $PERL5LIB --prefix PATH : ${wget}/bin:${git}/bin:${nix}/bin:${gnutar}/bin:${xz}/bin:$out/bin

    patchShebangs $out/bin
  '';

}
