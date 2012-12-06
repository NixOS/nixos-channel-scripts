#! /bin/sh

trash=/data/releases/.trash
mkdir -p $trash

# Remove garbage temporary directories.
find /data/releases/nixos/ /data/releases/nixpkgs/ -maxdepth 1 -name ".tmp*" -mtime +7 | while read rel; do
    echo "removing temporary directory $rel"
    mv $rel $trash/
done

# Remove old NixOS releases. 
find /data/releases/nixos/ -maxdepth 1 -name "nixos-*pre*" -mtime +30 | sort | while read rel; do 
    if [ -e $rel/keep ]; then 
	echo "keeping NixOS release $rel"
	continue
    fi
    echo "removing old NixOS release $rel"
    mv $rel $trash/
done

# Remove old Nixpkgs releases. 
find /data/releases/nixpkgs/ -maxdepth 1 -name "nixpkgs-*pre*" -mtime +30 | sort | while read rel; do 
    if [ -e $rel/keep ]; then 
	echo "keeping Nixpkgs release $rel"
	continue
    fi
    echo "removing old Nixpkgs release $rel"
    mv $rel $trash/
done

# Remove unreferenced NARs/patches.
./print-dead-files.pl /data/releases/patches/all-patches $(find /data/releases -name MANIFEST | grep -v '\.trash' | grep -v '\.tmp') \
| xargs -d '\n' sh -c 'find "$@" -mtime +50 -print' \
| xargs -d '\n' mv -v --target-directory=$trash
