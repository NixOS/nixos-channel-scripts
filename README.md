## Building

    $ nix-build

## Running

    $ ./result/bin/mirror-nixos-branch nixos-16.03-small https://hydra.nixos.org/job/nixos/release-16.03-small/tested/latest-finished

    $ ./result/bin/mirror-nixos-branch nixos-unstable-small https://hydra.nixos.org/job/nixos/unstable-small/tested/latest-finished

    $ ./result/bin/generate-programs-index /data/releases/nixos-files.sqlite /data/releases/nixos/unstable-small/nixos-16.09pre89017.9db1990-tmp/unpack/nixos-16.09pre89017.9db1990/programs.sqlite http://nix-cache.s3.amazonaws.com/ /data/releases/nixos/unstable-small/nixos-16.09pre89017.9db1990-tmp/store-paths /data/releases/nixos/unstable-small/nixos-16.09pre89017.9db1990-tmp/unpack/nixos-16.09pre89017.9db1990/nixpkgs