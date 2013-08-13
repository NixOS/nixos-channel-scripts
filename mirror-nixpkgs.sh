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

echo "release is ‘$release’ (build $releaseId), eval is ‘$url’"

if [ -d $releaseDir ]; then
    echo "release already exists"
else
    tmpDir=$releasesDir/.tmp-$release-$$
    mkdir -p $tmpDir

    echo $url > $tmpDir/src-url

    perl -w ./mirror-channel.pl "$url/channel" "$tmpDir" \
        nix-cache http://cache.nixos.org \
        /data/releases/patches/all-patches "$url/job/tarball/download/4"

    mv $tmpDir $releaseDir
fi

htaccess=$channelsDir/.htaccess-nixpkgs
echo "Redirect /channels/$channelName http://nixos.org/releases/nixpkgs/$release" > $htaccess.tmp
echo "Redirect /releases/nixpkgs/channels/$channelName http://nixos.org/releases/nixpkgs/$release" >> $htaccess.tmp
ln -sfn $releaseDir $channelsDir/$channelName # dummy symlink
mv $htaccess.tmp $htaccess

# Copy over to nixos.org
cd /data/releases
rsync -avR nixpkgs hydra-mirror@nixos.org:/data/releases --exclude nixpkgs/.htaccess --delete
rsync -avR channels/.htaccess-nixpkgs channels/nixpkgs-unstable hydra-mirror@nixos.org:/data/releases
ssh nixos.org "flock -x $channelsDir/.htaccess.lock -c \"cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess\""
