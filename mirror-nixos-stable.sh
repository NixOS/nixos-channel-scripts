#! /bin/sh -e

version="$1"
if [ -z "$version" ]; then echo "syntax: $0 VERSION"; exit 1; fi

releaseDir=$(./mirror-nixos-branch.sh "$version" "release-$version")
echo $releaseDir

release=$(basename $releaseDir)

# Generate a .htaccess with some symbolic redirects to the latest ISOs.
htaccess=/data/releases/nixos/.htaccess

link() {
    local name="$1"
    local wildcard="$2"
    fn=$(cd $releaseDir && echo $wildcard)
    echo "Redirect /releases/nixos/$name $baseURL/$fn" >> $htaccess.tmp
    echo "Redirect /releases/nixos/${name}-sha256 $baseURL/${fn}.sha256" >> $htaccess.tmp
}

baseURL="/releases/nixos/$version/$release"
echo "Redirect /releases/nixos/latest $baseURL" > $htaccess.tmp
link latest-iso-minimal-i686-linux "nixos-minimal-*-i686-linux.iso"
link latest-iso-minimal-x86_64-linux "nixos-minimal-*-x86_64-linux.iso"
link latest-iso-graphical-i686-linux "nixos-graphical-*-i686-linux.iso"
link latest-iso-graphical-x86_64-linux "nixos-graphical-*-x86_64-linux.iso"
link latest-ova-i686-linux "nixos-*-i686-linux.ova"
link latest-ova-x86_64-linux "nixos-*-x86_64-linux.ova"

mv $htaccess.tmp $htaccess

rsync -av $htaccess hydra-mirror@nixos.org:$htaccess >&2
