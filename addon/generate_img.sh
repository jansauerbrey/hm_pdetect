#!/bin/bash
#
# script to generate the CCU addon package.

# generate tempdir
mkdir -p tmp
rm -rf tmp/*

# copy all relevant stuff
cp -a update_script tmp/
cp -a common tmp/
cp -a rc.d tmp/
cp -a www tmp/
cp -a ../VERSION tmp/www/

# copy hm_pdetect main script + config
cp -a ../hm_pdetect.sh tmp/common/bin/

# generate archive
cd tmp
find . -not -name '.DS_Store' -not -name '*.sha256' -type f -print0 | xargs -0 sha256sum >hm_pdetect-$(cat ../../VERSION).sha256
tar --owner=root --group=root --exclude=.DS_Store -czvf ../hm_pdetect-$(cat ../../VERSION).tar.gz *
cd ..
rm -rf tmp
