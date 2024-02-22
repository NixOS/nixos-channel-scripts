{
  description = "Script for generating Nixpkgs/NixOS channels";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11-small";

  outputs = { self, nixpkgs }:
    {
      overlays.default = final: prev: {
        nixos-channel-native-programs = with final; stdenv.mkDerivation {
          name = "nixos-channel-native-programs";
          buildInputs = [
              nix
              pkg-config
              boehmgc
              nlohmann_json
              boost
              sqlite
          ];

          buildCommand = let
            nixHasSignalsHh = nixpkgs.lib.strings.versionAtLeast nix.version "2.19";
          in ''
            mkdir -p $out/bin

            g++ -Os -g ${./index-debuginfo.cc} -Wall -std=c++14 -o $out/bin/index-debuginfo -I . \
              $(pkg-config --cflags nix-main) \
              $(pkg-config --libs nix-main) \
              $(pkg-config --libs nix-store) \
              -lsqlite3 \
              ${nixpkgs.lib.optionalString nixHasSignalsHh "-DHAS_SIGNALS_HH"}
          '';
        };

        nixos-channel-scripts = with final; stdenv.mkDerivation {
          name = "nixos-channel-scripts";

          buildInputs = with perlPackages;
            [ nix
              sqlite
              makeWrapper
              perl
              FileSlurp
              LWP
              LWPProtocolHttps
              ListMoreUtils
              DBDSQLite
              NetAmazonS3
              brotli
              jq
              nixos-channel-native-programs
              nix-index
            ];

          buildCommand = ''
            mkdir -p $out/bin

            cp ${./mirror-nixos-branch.pl} $out/bin/mirror-nixos-branch
            wrapProgram $out/bin/mirror-nixos-branch \
              --set PERL5LIB $PERL5LIB \
              --set XZ_OPT "-T0" \
              --prefix PATH : ${lib.makeBinPath [ wget git nix gnutar xz rsync openssh nix-index nixos-channel-native-programs ]}

            patchShebangs $out/bin
          '';
        };

      };

      defaultPackage.x86_64-linux = (import nixpkgs {
        system = "x86_64-linux";
        overlays = [ self.overlays.default ];
      }).nixos-channel-scripts;
    };
}
