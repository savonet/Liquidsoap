#!/bin/sh

set -e

APK_FILE="$1"
TAG="$2"
USER="$3"
PASSWORD="$4"
ARCHITECTURE="$5"
DOCKER_PLATFORM="$6"

cp "$APK_FILE" .

docker login -u "$USER" -p "$PASSWORD"

docker buildx build \
  --pull \
  --platform "${DOCKER_PLATFORM}" \
  --no-cache \
  --build-arg "APK_FILE=$APK_FILE" \
  --file .github/docker/Dockerfile.production-alpine \
  --tag "savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}" \
  --push \
  .

docker pull "savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}"

docker tag \
  "savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}" \
  "ghcr.io/savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}"

docker push "ghcr.io/savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}"
