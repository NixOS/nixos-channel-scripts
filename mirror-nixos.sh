#! /bin/sh -e

releaseUrl=http://hydra.nixos.org/job/nixos/trunk-combined/tested/latest-finished
releasesDir=/data/releases/nixos
channelsDir=/data/releases/channels
channelName=nixos-unstable
curl="curl --silent --show-error --fail"
wget="wget --no-verbose --content-disposition"

json=$($curl -L -H 'Accept: application/json' $releaseUrl)

releaseId=$(echo "$json" | json id)
if [ -z "$releaseId" ]; then echo "Failed to get release id"; exit 1; fi

release=$(echo "$json" | json nixname)
if [ -z "$release" ]; then echo "Failed to get release"; exit 1; fi

url=$($curl --head http://hydra.nixos.org/build/$releaseId/eval | sed 's/Location: \(.*\)\r/\1/; t; d')
if [ -z "$url" ]; then exit 1; fi

releaseDir=$releasesDir/$release

echo "release is ‘$release’ (build $releaseId), eval is ‘$url’, dir is ‘$releaseDir’"

if [ -d $releaseDir ]; then
    echo "release already exists"
else
    tmpDir=$releasesDir/.tmp-$release-$$
    mkdir -p $tmpDir

    echo $url > $tmpDir/src-url

    # Copy the manual.
    $curl -L $url/job/nixos.manual/output/out | bzip2 -d | nix-store --restore $tmpDir/foo
    mv $tmpDir/foo/share/doc/nixos $tmpDir/manual
    rm -rf $tmpDir/foo
    ln -s manual.html $tmpDir/manual/index.html

    $wget --directory=$tmpDir $url/job/nixos.iso_minimal.i686-linux/download
    $wget --directory=$tmpDir $url/job/nixos.iso_minimal.x86_64-linux/download
    $wget --directory=$tmpDir $url/job/nixos.iso_graphical.i686-linux/download
    $wget --directory=$tmpDir $url/job/nixos.iso_graphical.x86_64-linux/download
    $wget --directory=$tmpDir $url/job/nixos.ova.i686-linux/download
    $wget --directory=$tmpDir $url/job/nixos.ova.x86_64-linux/download

    perl -w ./mirror-channel.pl "$url/channel" "$tmpDir" \
        nix-cache http://cache.nixos.org \
        /data/releases/patches/all-patches "$url/job/nixos.channel/download/1"

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
fn=$(cd $releaseDir && echo nixos-*-i686-linux.ova)
echo "Redirect /releases/nixos/latest-ova-i686-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-*-x86_64-linux.ova)
echo "Redirect /releases/nixos/latest-ova-x86_64-linux http://nixos.org/releases/nixos/$release/$fn" >> $htaccess.tmp

mv $htaccess.tmp $htaccess

# Copy over to nixos.org.
cd /data/releases
rsync -avR nixos hydra-mirror@nixos.org:/data/releases --exclude nixos/.htaccess --delete
rsync -avR channels/.htaccess-nixos channels/nixos-unstable nixos/.htaccess hydra-mirror@nixos.org:/data/releases
ssh nixos.org "flock -x $channelsDir/.htaccess.lock -c \"cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess\""
