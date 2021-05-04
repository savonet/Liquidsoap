#!/bin/sh

set -e

eval $(opam config env)

# Remove after next base image rebuild
opam install -y ocurl posix-time2

cd /tmp/liquidsoap-full

git pull
make clean
make update
./liquidsoap/.github/scripts/checkout-deps.sh

cd liquidsoap
git fetch origin $GITHUB_SHA
git checkout $GITHUB_SHA

export PKG_CONFIG_PATH=/usr/share/pkgconfig/pkgconfig

./bootstrap
./configure --prefix=/usr --includedir=\${prefix}/include --mandir=\${prefix}/share/man \
            --infodir=\${prefix}/share/info --sysconfdir=/etc --localstatedir=/var \
            --with-camomile-data-dir=/usr/share/liquidsoap/camomile

cd liquidsoap
make
make doc
