#! /bin/sh -e

releaseUrl=http://hydra.nixos.org/job/nixpkgs/trunk/unstable/latest-finished
releasesDir=/data/releases/nixpkgs
channelsDir=/data/releases/channels
channelName=nixpkgs-unstable
curl="curl --silent --show-error --fail"

json=$($curl -L -H 'Accept: application/json' $releaseUrl)

releaseId=$(echo "$json" | json id)
if [ -z "$releaseId" ]; then echo "Failed to get release id"; exit 1; fi

release=$(echo "$json" | json nixname)
if [ -z "$release" ]; then echo "Failed to get release"; exit 1; fi

url=$($curl --head http://hydra.nixos.org/build/$releaseId/eval | sed 's/Location: \(.*\)\r/\1/; t; d')
if [ -z "$url" ]; then exit 1; fi

releaseDir=$releasesDir/$release

echo "release is ‘$release’ (build $releaseId), eval is ‘$url’, dir is ‘$releaseDir’" >&2

if [ -d $releaseDir ]; then
    echo "release already exists" >&2
else
    tmpDir=$releasesDir/.tmp-$release-$$
    mkdir -p $tmpDir

    echo $url > $tmpDir/src-url

    perl -w ./mirror-channel.pl "$url/channel" "$tmpDir" \
        nix-cache https://cache.nixos.org \
        "$url/job/tarball/download/1"

    # Extract the manual.
    $curl -L $url/job/manual/output/out | bzip2 -d | nix-store --restore $tmpDir/foo
    mv $tmpDir/foo/share/doc/nixpkgs $tmpDir/manual
    rm -rf $tmpDir/foo
    ln -s manual.html $tmpDir/manual/index.html

    mv $tmpDir $releaseDir
fi

# Prevent concurrent writes to the channels and the Git clone.
exec 10>$channelsDir/.htaccess.lock
flock 10

# Copy over to nixos.org.
cd "$releasesDir"
rsync -avR . hydra-mirror@nixos.org:"$releasesDir" --delete >&2

# Update the channel.
htaccess=$channelsDir/.htaccess-$channelName
echo "Redirect /channels/$channelName /releases/nixpkgs/$release" > $htaccess.tmp
echo "Redirect /releases/nixpkgs/channels/$channelName /releases/nixpkgs/$release" >> $htaccess.tmp # obsolete
mv $htaccess.tmp $htaccess
ln -sfn $releaseDir $channelsDir/$channelName # dummy symlink

cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess

cd "$channelsDir"
rsync -avR . hydra-mirror@nixos.org:"$channelsDir" --delete >&2
