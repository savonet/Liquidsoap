#!/bin/sh

set -e

CPU_CORES="$1"

export CPU_CORES

eval "$(opam config env)"

echo "::group::Preparing bindings"

cd /tmp/liquidsoap-full

git remote set-url origin https://github.com/savonet/liquidsoap-full.git
git fetch --recurse-submodules=no && git checkout origin/master -- Makefile.git
git reset --hard
git pull

git pull
make clean
make public
make update

echo "::endgroup::"

echo "::group::Checking out CI commit"

cd /tmp/liquidsoap-full/liquidsoap

git fetch origin "$GITHUB_SHA"
git checkout "$GITHUB_SHA"
mv .github /tmp
rm -rf ./*
mv /tmp/.github .
git reset --hard

echo "::endgroup::"

echo "::group::Setting up specific dependencies"

git clone https://github.com/savonet/ocaml-xiph.git
cd ocaml-xiph
opam install -y .
cd ..

cd /tmp
rm -rf ocaml-posix
git clone https://github.com/savonet/ocaml-posix.git
cd ocaml-posix
opam pin -ny .
opam install -y posix-socket.2.2.0 posix-base.2.2.0 posix-time2.2.2.0 posix-types.2.2.0

cd /tmp/liquidsoap-full/liquidsoap

./.github/scripts/checkout-deps.sh

git clone https://github.com/savonet/ocaml-mem_usage.git
cd ocaml-mem_usage
opam install -y .
cd ..

opam update
opam remove -y jemalloc
opam install -y tls.1.0.2 ca-certs mirage-crypto-rng cstruct saturn_lockfree.0.5.0 ppx_hash memtrace xml-light odoc

cd /tmp/liquidsoap-full

# TODO: Remove gstreamer from liquidsoap-full
sed -e 's@ocaml-gstreamer@#ocaml-gstreamer@' -i PACKAGES

# TODO: Remove taglib from liquidsoap-full
sed -e 's@ocaml-taglib@#ocaml-taglib@' -i PACKAGES

export PKG_CONFIG_PATH=/usr/share/pkgconfig/pkgconfig

echo "::endgroup::"

echo "::group::Compiling"

cd /tmp/liquidsoap-full

# Workaround
touch liquidsoap/configure

./configure --prefix=/usr \
  --includedir="\${prefix}/include" \
  --mandir="\${prefix}/share/man" \
  --infodir="\${prefix}/share/info" \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --with-camomile-data-dir=/usr/share/liquidsoap/camomile \
  CFLAGS=-g

# Workaround
rm liquidsoap/configure

OCAMLPATH="$(cat .ocamlpath)"
export OCAMLPATH

cd /tmp/liquidsoap-full/liquidsoap
dune build @doc @doc-private
dune build --profile=release

echo "::endgroup::"

echo "::group::Print build config"

dune exec -- liquidsoap --build-config

echo "::endgroup::"

echo "::group::Basic tests"

cd /tmp/liquidsoap-full/liquidsoap

dune exec -- liquidsoap --version
dune exec -- liquidsoap --check 'print("hello world")'

echo "::endgroup::"
