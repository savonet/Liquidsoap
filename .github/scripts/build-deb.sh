#!/bin/sh

dch --create --distribution unstable --package "${LIQ_PACKAGE}" --newversion "1:${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}" "Build ${COMMIT_SHORT}"

set -e

GITHUB_SHA="$1"
BRANCH="$2"
DOCKER_TAG="$3"
PLATFORM="$4"
IS_ROLLING_RELEASE="$5"
IS_RELEASE="$6"
MINIMAL_EXCLUDE_DEPS="$7"
DEB_RELEASE=1

ARCH=$(dpkg --print-architecture)

COMMIT_SHORT=$(echo "${GITHUB_SHA}" | cut -c-7)

export DEBFULLNAME="The Savonet Team"
export DEBEMAIL="savonet-users@lists.sourceforge.net"

cd /tmp/liquidsoap-full/liquidsoap

eval "$(opam config env)"
OCAMLPATH="$(cat ../.ocamlpath)"
export OCAMLPATH

LIQ_VERSION=$(opam show -f version ./liquidsoap.opam | cut -d'-' -f 1)
LIQ_TAG=$(echo "${DOCKER_TAG}" | sed -e 's#_#-#g')

if [ -n "${IS_ROLLING_RELEASE}" ]; then
  LIQ_PACKAGE="liquidsoap-${COMMIT_SHORT}"
elif [ -n "${IS_RELEASE}" ]; then
  LIQ_PACKAGE="liquidsoap"
else
  TAG=$(echo "${BRANCH}" | tr '[:upper:]' '[:lower:]' | sed -e 's#[^0-9^a-z^A-Z^.^-]#-#g')
  LIQ_PACKAGE="liquidsoap-${TAG}"
fi

echo "::group:: build ${LIQ_PACKAGE}.."

cp -rf .github/debian .

rm -rf debian/changelog

cp -f debian/control.in debian/control

sed -e "s#@LIQ_PACKAGE@#${LIQ_PACKAGE}#g" -i debian/control

dch --create --distribution unstable --package "${LIQ_PACKAGE}" --newversion "1:${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}" "Build ${COMMIT_SHORT}"

fakeroot debian/rules binary

echo "::endgroup::"

echo "::group:: save build config for ${LIQ_PACKAGE}.."

./liquidsoap --build-config > "/tmp/${GITHUB_RUN_NUMBER}/${DOCKER_TAG}_${PLATFORM}/debian/${LIQ_PACKAGE}_${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}.config"

echo "::endgroup::"

echo "::group:: build ${LIQ_PACKAGE}-minimal.."

eval "opam remove --force -y $MINIMAL_EXCLUDE_DEPS"

cd /tmp/liquidsoap-full
cp PACKAGES.minimal PACKAGES
rm .ocamlpath
cd liquidsoap
./.github/scripts/build-posix.sh 1
OCAMLPATH="$(cat ../.ocamlpath)"
export OCAMLPATH

rm -rf debian/changelog

cp -f debian/control.in debian/control

sed -e "s#@LIQ_PACKAGE@#${LIQ_PACKAGE}-minimal#g" -i debian/control

cp -rf debian/rules-minimal debian/rules

dch --create --distribution unstable --package "${LIQ_PACKAGE}-minimal" --newversion "1:${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}" "Build ${COMMIT_SHORT}"

fakeroot debian/rules binary

echo "::endgroup::"

echo "::group:: save build config for ${LIQ_PACKAGE}.."

./liquidsoap --build-config > "/tmp/${GITHUB_RUN_NUMBER}/${DOCKER_TAG}_${PLATFORM}/debian/${LIQ_PACKAGE}-minimal_${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}.config"

echo "::endgroup::"

cp /tmp/liquidsoap-full/*.deb "/tmp/${GITHUB_RUN_NUMBER}/${DOCKER_TAG}_${PLATFORM}/debian"

echo "##[set-output name=basename;]${LIQ_PACKAGE}_${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}_$ARCH"
echo "##[set-output name=basename-minimal;]${LIQ_PACKAGE}-minimal_${LIQ_VERSION}-${LIQ_TAG}-${DEB_RELEASE}_$ARCH"
