#! /bin/sh 
./print-dead-files.pl /data/releases/patches/all-patches $(find /data/releases -name MANIFEST | grep -v '\.trash' | grep -v '\.tmp') | sort > /tmp/dead
mkdir -p /data/releases/.trash/
xargs -d '\n' sh -c 'find "$@" -mtime +100 -print' < /tmp/dead | xargs -d '\n' mv -v --target-directory=/data/releases/.trash/
