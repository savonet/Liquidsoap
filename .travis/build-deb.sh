#!/bin/sh

set -e

TRAVIS_COMMIT=$1
TRAVIS_BRANCH=$2
TRAVIS_PULL_REQUEST_BRANCH=$3
TRAVIS_PULL_REQUEST=$4

DEBFULLNAME="The Savonet Team"
DEBEMAIL="savonet-users@lists.sourceforge.net"

if test "${TRAVIS_PULL_REQUEST}" = "false"; then
  BRANCH="${TRAVIS_BRANCH}"
else
  BRANCH="${TRAVIS_PULL_REQUEST_BRANCH}"
fi

eval $(opam config env)

cd /tmp/liquidsoap-full/liquidsoap

dch --create --distribution unstable --package "liquidsoap" --newversion "0+${COMMIT}-1" "Build ${COMMIT}"

fakeroot debian/rules binary

dch --create --distribution unstable --package "liquidsoap" --newversion "0+${BRANCH}-1" "Build ${BRANCH}"

fakeroot debian/rules binary

mkdir -p /tmp/debian/pkgs

cp /tmp/liquidsoap-full/*.deb /tmp/debian/pkgs
