#! /bin/sh -e

viewUrl=http://hydra.nixos.org/view/nixpkgs/unstable/latest-finished
releasesDir=/data/releases/nixpkgs
channelsDir=/data/releases/channels
channelName=nixpkgs-unstable
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
	/data/releases/binary-cache http://nixos.org/binary-cache \
	/data/releases/patches/all-patches "$url/tarball/download/4"

    mv $tmpDir $releaseDir
fi

htaccess=$channelsDir/.htaccess-nixpkgs
echo "Redirect /channels/$channelName http://nixos.org/releases/nixpkgs/$release" > $htaccess.tmp
echo "Redirect /releases/nixpkgs/channels/$channelName http://nixos.org/releases/nixpkgs/$release" >> $htaccess.tmp
ln -sfn $releaseDir $channelsDir/$channelName # dummy symlink
mv $htaccess.tmp $htaccess
flock -x $channelsDir/.htaccess.lock -c "cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess"
