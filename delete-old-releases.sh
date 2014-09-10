#! /bin/sh

set -e

trash=/data/releases/.trash
mkdir -p $trash

# Remove garbage temporary directories.
find /data/releases/nixos/ /data/releases/nixpkgs/ -maxdepth 1 -name ".tmp*" -mtime +7 | while read rel; do
    echo "removing temporary directory $rel" >&2
    mv $rel $trash/
done

# Remove old NixOS releases. 
find /data/releases/nixos/unstable/ /data/releases/nixos/??.??/ -maxdepth 1 -name "nixos-*pre*" -mtime +7 | sort | while read rel; do 
    if [ -e $rel/keep ]; then 
	echo "keeping NixOS release $rel" >&2
	continue
    fi
    echo "removing old NixOS release $rel" >&2
    mv $rel $trash/
done

# Remove old Nixpkgs releases. 
find /data/releases/nixpkgs/ -maxdepth 1 -name "nixpkgs-*pre*" -mtime +30 | sort | while read rel; do 
    if [ -e $rel/keep ]; then 
	echo "keeping Nixpkgs release $rel" >&2
	continue
    fi
    echo "removing old Nixpkgs release $rel" >&2
    mv $rel $trash/
done

exit 0

# Remove unreferenced NARs/patches (but only if they're older than 2
# weeks, to prevent messing with binary patch generation in progress).
./print-dead-files.pl /data/releases/patches/all-patches $(find /data/releases/nix* /data/releases/patchelf -name MANIFEST | grep -v '\.trash' | grep -v '\.tmp') \
| xargs -d '\n' sh -c 'find "$@" -mtime +14 -print' \
| xargs -d '\n' mv -v --target-directory=$trash
