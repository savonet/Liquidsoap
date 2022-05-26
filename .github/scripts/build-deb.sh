dch --create --distribution unstable --package "${LIQ_PACKAGE}" --newversion "1:${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}" "Build ${COMMIT_SHORT}"#!/bin/sh

set -e

GITHUB_SHA=$1
BRANCH=$2
DOCKER_TAG=$3
PLATFORM=$4
IS_ROLLING_RELEASE=$5
IS_RELEASE=$6
DEB_RELEASE=1

ARCH=`dpkg --print-architecture`

COMMIT_SHORT=`echo "${GITHUB_SHA}" | cut -c-7`

export DEBFULLNAME="The Savonet Team"
export DEBEMAIL="savonet-users@lists.sourceforge.net"

cd /tmp/liquidsoap-full/liquidsoap

eval $(opam config env)
export OCAMLPATH=`cat ../.ocamlpath`

LIQ_VERSION=`opam show -f version ./liquidsoap.opam | cut -d'-' -f 1`
LIQ_TAG=`echo ${DOCKER_TAG} | sed -e 's#_#-#g'`

if [ -n "${IS_ROLLING_RELEASE}" ]; then
  LIQ_PACKAGE="liquidsoap-${COMMIT_SHORT}"
elif [ -n "${IS_RELEASE}" ]; then
  LIQ_PACKAGE="liquidsoap"
else
  TAG=`echo "${BRANCH}" | tr '[:upper:]' '[:lower:]' | sed -e 's#[^0-9^a-z^A-Z^.^-]#-#g'`
  LIQ_PACKAGE="liquidsoap-${TAG}"
fi

echo "Building ${LIQ_PACKAGE}.."

cp -rf .github/debian .

rm -rf debian/changelog

cp -f debian/control.in debian/control

sed -e "s#@LIQ_PACKAGE@#${LIQ_PACKAGE}#g" -i debian/control

dch --create --distribution unstable --package "${LIQ_PACKAGE}" --newversion "1:${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}" "Build ${COMMIT_SHORT}"

fakeroot debian/rules binary

cp /tmp/liquidsoap-full/*.deb /tmp/${GITHUB_RUN_NUMBER}/${DOCKER_TAG}_${PLATFORM}/debian

echo "##[set-output name=basename;]${LIQ_PACKAGE}_${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}_$ARCH"
