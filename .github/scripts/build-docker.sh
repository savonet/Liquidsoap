#!/bin/sh

set -e

DEB_FILE="$1"
DEB_DEBUG_FILE="$2"
TAG="$3"
USER="$4"
PASSWORD="$5"
ARCHITECTURE="$6"
DOCKER_PLATFORM="$7"

cp "$DEB_FILE" "$DEB_DEBUG_FILE" .

if [ "${ARCHITECTURE}" = "armhf" ]; then
  DOCKERFILE=.github/docker/Dockerfile-armhf.production
else
  DOCKERFILE=.github/docker/Dockerfile.production
fi

docker login -u "$USER" -p "$PASSWORD"

docker buildx build \
  --pull \
  --platform "${DOCKER_PLATFORM}" \
  --no-cache \
  --build-arg "DEB_FILE=$DEB_FILE" \
  --build-arg "DEB_DEBUG_FILE=$DEB_DEBUG_FILE" \
  --file "${DOCKERFILE}" \
  --tag "savonet/liquidsoap-ci-build:${TAG}_${ARCHITECTURE}" \
  --push \
  .

docker pull "savonet/liquidsoap-ci-build:${TAG}_${ARCHITECTURE}"

docker tag \
  "savonet/liquidsoap-ci-build:${TAG}_${ARCHITECTURE}" \
  "ghcr.io/savonet/liquidsoap-ci-build:${TAG}_${ARCHITECTURE}"

docker push "ghcr.io/savonet/liquidsoap-ci-build:${TAG}_${ARCHITECTURE}"
