{
  description = "Script for generating Nixpkgs/NixOS channels";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";

  outputs =
    { self, nixpkgs }:
    {
      overlays.default = final: prev: {
        nixos-channel-native-programs = final.stdenv.mkDerivation {
          name = "nixos-channel-native-programs";

          strictDeps = true;

          nativeBuildInputs = with final.buildPackages; [
            pkg-config
          ];

          buildInputs = with final; [
            nixVersions.nix_2_28
            nlohmann_json
            boost
          ];

          buildCommand = ''
            mkdir -p $out/bin

            $CXX \
              -Os -g -Wall \
              -std=c++14 \
              $(pkg-config --libs --cflags nix-store) \
              $(pkg-config --libs --cflags nix-main) \
              -I . \
              ${./index-debuginfo.cc} \
              -o $out/bin/index-debuginfo
          '';
        };

        nixos-channel-scripts = final.stdenv.mkDerivation {
          name = "nixos-channel-scripts";

          strictDeps = true;

          nativeBuildInputs = with final.buildPackages; [
            makeWrapper
          ];

          buildInputs = with final.perlPackages; [
            final.perl
            FileSlurp
            LWP
            LWPProtocolHttps
            ListMoreUtils
            DBDSQLite
            NetAmazonS3
          ];

          buildCommand = ''
            mkdir -p $out/bin

            cp ${./mirror-nixos-branch.pl} $out/bin/mirror-nixos-branch
            wrapProgram $out/bin/mirror-nixos-branch \
              --set PERL5LIB $PERL5LIB \
              --set XZ_OPT "-T0" \
              --prefix PATH : ${
                final.lib.makeBinPath (
                  with final;
                  [
                    wget
                    git
                    nix
                    gnutar
                    xz
                    rsync
                    openssh
                    nix-index
                    nixos-channel-native-programs
                  ]
                )
              }

            patchShebangs $out/bin
          '';
        };

      };

      packages.x86_64-linux.default =
        (import nixpkgs {
          system = "x86_64-linux";
          overlays = [ self.overlays.default ];
        }).nixos-channel-scripts;

      checks.x86_64-linux.default = self.packages.x86_64-linux.default;
    };
}
