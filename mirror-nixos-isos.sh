#! /bin/sh -e

# This script downloads the latest NixOS ISO images from the "tested"
# view in Hydra to $mirrorDir (http://nixos.org/releases/nixos).

curl="curl --silent --show-error --fail"
wget="wget --no-verbose --content-disposition"

mirrorDir=/data/releases/nixos

url=$($curl --head http://hydra.nixos.org/view/nixos/tested/latest | sed 's/Location: \(.*\)\r/\1/; t; d')

if [ -z "$url" ]; then exit 1; fi

echo "View page is $url"

release=$($curl $url | sed 's|<h1>View.*(<tt>\(.*\)</tt>.*|\1|; t; d')

if [ -z "$release" ]; then echo "Failed to get release"; exit 1; fi

echo "Release is $release"

releaseDir=$mirrorDir/$release

if [ -d $releaseDir ]; then
    echo "Release already exists"
else

    tmpDir=$mirrorDir/.tmp-$release-$$
    mkdir -p $tmpDir

    $wget --directory=$tmpDir $url/tarball/download
    $wget --directory=$tmpDir $url/iso_minimal-i686-linux/download
    $wget --directory=$tmpDir $url/iso_minimal-x86_64-linux/download
    $wget --directory=$tmpDir $url/iso_graphical-i686-linux/download
    $wget --directory=$tmpDir $url/iso_graphical-x86_64-linux/download

    mv $tmpDir $releaseDir

fi

#ln -sfn $release $mirrorDir/latest

# Generate a .htaccess with some symbolic redirects to the latest version.
htaccess=$mirrorDir/.htaccess

echo "Redirect /releases/nixos/latest http://nixos.org/releases/nixos/$release" > $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-minimal-*-i686-linux.iso)
echo "Redirect /releases/nixos/latest-iso-minimal-i686-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-minimal-*-x86_64-linux.iso)
echo "Redirect /releases/nixos/latest-iso-minimal-x86_64-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-graphical-*-i686-linux.iso)
echo "Redirect /releases/nixos/latest-iso-graphical-i686-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-graphical-*-x86_64-linux.iso)
echo "Redirect /releases/nixos/latest-iso-graphical-x86_64-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp

mv $htaccess.tmp $htaccess
