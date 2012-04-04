#! /bin/sh -e
src="$1"
dst="$2"

if test ! -d "$src" -o ! -d "$dst"; then
    echo "syntax: $0 source-dir dest-dir"
    exit 1
fi

nix-generate-patches \
  /data/releases/nars \
  /data/releases/patches \
  http://nixos.org/releases/patches \
  "$src/MANIFEST" "$dst/MANIFEST"
