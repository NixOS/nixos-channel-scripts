#! /bin/sh -e

viewUrl=http://hydra.nixos.org/view/nixos/tested/latest-finished
releasesDir=/data/releases/nixos
channelsDir=/data/releases/channels
channelName=nixos-unstable
curl="curl --silent --show-error --fail"
wget="wget --no-verbose --content-disposition"

url=$($curl --head $viewUrl | sed 's/Location: \(.*\)\r/\1/; t; d')
if [ -z "$url" ]; then exit 1; fi

echo "View page is $url"

release=$($curl $url | sed 's|.*<h1>.*View \(.*\)</small.*|\1|; t; d')
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

    $wget --directory=$tmpDir $url/nixos.iso_minimal-i686-linux/download
    $wget --directory=$tmpDir $url/nixos.iso_minimal-x86_64-linux/download
    $wget --directory=$tmpDir $url/nixos.iso_graphical-i686-linux/download
    $wget --directory=$tmpDir $url/nixos.iso_graphical-x86_64-linux/download

    perl -w ./mirror-channel.pl "$url/eval/channel" "$tmpDir" \
	/data/releases/binary-cache http://nixos.org/binary-cache \
	/data/releases/patches/all-patches "$url/nixos.channel/download/1"

    # Generate the programs.sqlite database and put it in nixexprs.tar.xz.
    mkdir $tmpDir/unpack
    tar xfJ $tmpDir/nixexprs.tar.xz -C $tmpDir/unpack
    exprDir=$(echo $tmpDir/unpack/*)
    ./generate-programs-index.pl "$exprDir" "$exprDir/programs.sqlite"
    tar cfJ $tmpDir/nixexprs.tar.xz -C $tmpDir/unpack "$(basename "$exprDir")"
    rm -rf $tmpDir/unpack

    mv $tmpDir $releaseDir
fi

htaccess=$channelsDir/.htaccess-nixos
echo "Redirect /channels/$channelName http://nixos.org/releases/nixos/$release" > $htaccess.tmp
echo "Redirect /releases/nixos/channels/$channelName http://nixos.org/releases/nixos/$release" >> $htaccess.tmp
ln -sfn $releaseDir $channelsDir/$channelName # dummy symlink
mv $htaccess.tmp $htaccess
flock -x $channelsDir/.htaccess.lock -c "cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess"

# Generate a .htaccess with some symbolic redirects to the latest ISOs.
htaccess=$releasesDir/.htaccess

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
