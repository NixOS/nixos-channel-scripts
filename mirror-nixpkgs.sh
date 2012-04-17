#! /bin/sh -e

viewUrl=http://hydra.nixos.org/view/nixpkgs/unstable/latest-finished
releasesDir=/data/releases/nixpkgs
channelLink=/data/releases/nixpkgs/channels/nixpkgs-unstable
curl="curl --silent --show-error --fail"

url=$($curl --head $viewUrl | sed 's/Location: \(.*\)\r/\1/; t; d')
if [ -z "$url" ]; then exit 1; fi

echo "View page is $url"

release=$($curl $url | sed 's|.*<h1>View.*(<tt>\(.*\)</tt>.*|\1|; t; d')
if [ -z "$release" ]; then echo "Failed to get release"; exit 1; fi

echo "Release is $release"

releaseDir=$releasesDir/$release
echo $releaseDir

if [ -d $releaseDir ]; then
    echo "Release already exists"
else
    tmpDir=$releasesDir/.tmp-$release-$$
    mkdir -p $tmpDir

    echo $url > $tmpDir/src-url

    perl -w ./mirror-channel.pl "$url/eval/channel" "$tmpDir" \
	/data/releases/nars http://nixos.org/releases/nars \
	/data/releases/patches/all-patches "$url/tarball/download/4"

    mv $tmpDir $releaseDir
fi

htaccess=$(dirname $channelLink)/.htaccess
echo "Redirect /releases/nixpkgs/channels/nixpkgs-unstable http://nixos.org/releases/nixpkgs/$release" > $htaccess.tmp
ln -sfn $releaseDir $channelLink # dummy symlink
mv $htaccess.tmp $htaccess
