#! /bin/sh -e

releaseDir=$(./mirror-nixos-branch.sh unstable trunk-combined)
echo $releaseDir

release=$(basename $releaseDir)

# Generate a .htaccess with some symbolic redirects to the latest ISOs.
htaccess=/data/releases/nixos/.htaccess

baseURL="http://nixos.org/releases/nixos/unstable/$release"
echo "Redirect /releases/nixos/latest $baseURL" > $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-minimal-*-i686-linux.iso)
echo "Redirect /releases/nixos/latest-iso-minimal-i686-linux $baseURL/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-minimal-*-x86_64-linux.iso)
echo "Redirect /releases/nixos/latest-iso-minimal-x86_64-linux $baseURL/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-graphical-*-i686-linux.iso)
echo "Redirect /releases/nixos/latest-iso-graphical-i686-linux $baseURL/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-graphical-*-x86_64-linux.iso)
echo "Redirect /releases/nixos/latest-iso-graphical-x86_64-linux $baseURL/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-*-i686-linux.ova)
echo "Redirect /releases/nixos/latest-ova-i686-linux $baseURL/$fn" >> $htaccess.tmp
fn=$(cd $releaseDir && echo nixos-*-x86_64-linux.ova)
echo "Redirect /releases/nixos/latest-ova-x86_64-linux $baseURL/$fn" >> $htaccess.tmp

mv $htaccess.tmp $htaccess

rsync -av $htaccess hydra-mirror@nixos.org:$htaccess >&2
