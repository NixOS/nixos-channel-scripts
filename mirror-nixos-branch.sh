#! /bin/sh -e

branch="$1"
jobset="$2"

if [ -z "$branch" -o -z "$jobset" ]; then
    echo "Usage: $0 BRANCH-NAME JOBSET-NAME" >&2
    exit 1
fi

releaseUrl="http://hydra.nixos.org/job/nixos/$jobset/tested/latest-finished"
releasesDir="/data/releases/nixos/$branch"
channelsDir=/data/releases/channels
channelName=nixos-"$branch"
export GIT_DIR=/home/hydra-mirror/nixpkgs-channels

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

echo "release is ‘$release’ (build $releaseId), eval is ‘$url’, dir is ‘$releaseDir’" >&2

curRelease=$(basename $(readlink $channelsDir/$channelName 2> /dev/null) 2> /dev/null || true)

if [ -n "$curRelease" ]; then
    d="$(nix-instantiate --eval -E "builtins.compareVersions (builtins.parseDrvName \"$curRelease\").version (builtins.parseDrvName \"$release\").version")"
    if [ "$d" = 1 ]; then
	echo "channel would go back in time from $curRelease to $release, bailing out" >&2
	exit 1
    fi
fi

# Figure out the Git revision from which this release was
# built. FIXME: get this from Hydra directly.
shortRev=$(echo "$release" | sed 's/.*\.//')
rev=$(git rev-parse "$shortRev")
echo "revision is $rev" >&2

if [ -d $releaseDir ]; then
    echo "release already exists" >&2
else
    tmpDir="$(dirname $releaseDir)/.tmp-$release-$$"
    mkdir -p $tmpDir

    trap 'rm -rf -- "$tmpDir"' EXIT

    echo -n "$url" > $tmpDir/src-url
    echo -n "$rev" > $tmpDir/git-revision

    # Copy the manual.
    $curl -L $url/job/nixos.manual.x86_64-linux/output/out | bzip2 -d | nix-store --restore $tmpDir/foo
    mv $tmpDir/foo/share/doc/nixos $tmpDir/manual
    rm -rf $tmpDir/foo
    if ! [ -e $tmpDir/manual/index.html ]; then
        ln -s manual.html $tmpDir/manual/index.html
    fi

    $wget --directory=$tmpDir $url/job/nixos.iso_minimal.x86_64-linux/download
    if ! [[ $branch =~ small ]]; then
        $wget --directory=$tmpDir $url/job/nixos.iso_minimal.i686-linux/download
        $wget --directory=$tmpDir $url/job/nixos.iso_graphical.x86_64-linux/download
        $wget --directory=$tmpDir $url/job/nixos.iso_graphical.i686-linux/download
        $wget --directory=$tmpDir $url/job/nixos.ova.x86_64-linux/download
        $wget --directory=$tmpDir $url/job/nixos.ova.i686-linux/download
    fi

    shopt -s nullglob
    for i in $tmpDir/*.iso $tmpDir/*.ova; do
        nix-hash --type sha256 --flat $i > $i.sha256
    done
    shopt -u nullglob

    perl -w ./mirror-channel.pl "$url/channel" "$tmpDir" \
        nix-cache https://cache.nixos.org \
        "$url/job/nixos.channel/download/1"

    # Generate the programs.sqlite database and put it in nixexprs.tar.xz.
    mkdir $tmpDir/unpack
    tar xfJ $tmpDir/nixexprs.tar.xz -C $tmpDir/unpack
    exprDir=$(echo $tmpDir/unpack/*)
    ./generate-programs-index.pl "$exprDir" "$exprDir/programs.sqlite" "$tmpDir/MANIFEST"
    tar cfJ $tmpDir/nixexprs.tar.xz -C $tmpDir/unpack "$(basename "$exprDir")"
    rm -rf $tmpDir/unpack

    mv $tmpDir $releaseDir
    trap '' EXIT
fi

# Prevent concurrent writes to the channels and the Git clone.
exec 10>$channelsDir/.htaccess.lock
flock 10

# Copy over to nixos.org.
cd "$releasesDir"
rsync -avR . hydra-mirror@nixos.org:"$releasesDir" --exclude .htaccess --exclude ".tmp.*" --delete >&2

# Update the channel.
htaccess=$channelsDir/.htaccess-$channelName
echo "Redirect /channels/$channelName /releases/nixos/$branch/$release" > $htaccess.tmp
echo "Redirect /releases/nixos/channels/$channelName /releases/nixos/$branch/$release" >> $htaccess.tmp # obsolete
mv $htaccess.tmp $htaccess
ln -sfn $releaseDir $channelsDir/$channelName # dummy symlink

cat $channelsDir/.htaccess-nix* > $channelsDir/.htaccess

cd "$channelsDir"
rsync -avR . hydra-mirror@nixos.org:"$channelsDir" --delete >&2

# Update the nixpkgs-channels repo.
git remote update nixpkgs >&2
git push nixpkgs-channels "$rev:refs/heads/$channelName" >&2

echo "$releaseDir"
