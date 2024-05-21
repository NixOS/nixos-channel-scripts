{
  description = "Script for generating Nixpkgs/NixOS channels";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11-small";

  outputs = { self, nixpkgs }:
    {
      overlays.default = final: prev: {
        nix-index-unwrapped = (prev.nix-index-unwrapped.override {
          rustPlatform = final.rustPackages_1_76.rustPlatform;
        }).overrideAttrs(old: rec {
          version = "0.1.7-unstable-2024-05-11";
          
          # commit with proper HTTPS fixes
          # FIXME: unpin after next release 
          src = final.fetchFromGitHub {
            owner = "nix-community";
            repo = "nix-index";
            rev = "195fb3525038e40836b8d286371365f5e7857c0c";
            hash = "sha256-Cw6Q9rHcLjPKzab5O4G7cetFAaTZCex2VLvYIhJCbpg=";
          };

          cargoDeps = final.rustPlatform.fetchCargoTarball {
            inherit src;
            hash = "sha256-Pl56f8FU/U/x4gkTt5yXxE8FVQ/pGBDuxxP7HrfsaBc=";
          };
        });

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
              nix-index-unwrapped
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
