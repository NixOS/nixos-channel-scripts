{ pkgs ? (import <nixpkgs> {}) }:

pkgs.buildPerlPackage {
  name = "nixos-channel-scripts";
  buildInputs = with pkgs.perlPackages; [ DBI DBDSQLite ];
}
