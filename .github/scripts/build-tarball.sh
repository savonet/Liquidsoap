#!/bin/sh

set -e

eval $(opam config env)

# Remove after liquidsoap 2.0 release
opam install -y posix-time2

cd /tmp/liquidsoap-full

git remote set-url origin https://github.com/savonet/liquidsoap-full.git
git fetch --recurse-submodules=no && git checkout origin/master -- Makefile.git
make public
git reset --hard

git pull
make clean
make public
make update

cd liquidsoap
git fetch origin $GITHUB_SHA
git checkout $GITHUB_SHA

./.github/scripts/checkout-deps.sh

cd /tmp/liquidsoap-full

export PKG_CONFIG_PATH=/usr/share/pkgconfig/pkgconfig

./bootstrap
./configure --prefix=/usr --includedir=\${prefix}/include --mandir=\${prefix}/share/man \
            --infodir=\${prefix}/share/info --sysconfdir=/etc --localstatedir=/var \
            --with-camomile-data-dir=/usr/share/liquidsoap/camomile

cd liquidsoap
make
make -C doc language.dtd liquidsoap.1 content/protocols.md content/reference.md content/reference-extras.md content/settings.md
make tarball
