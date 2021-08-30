#!/bin/sh

set -e

TAG=$1
USER=$2
PASSWORD=$3
GHCR_USER=$4
GHCR_PASSWORD=$5

rm -rf ~/.docker/config.json
mkdir -p ~/.docker
echo "{ \"experimental\": \"enabled\" }" > ~/.docker/config.json

docker login -u "$USER" -p "$PASSWORD"

docker manifest create savonet/liquidsoap:$TAG --amend savonet/liquidsoap-ci-build:${TAG}_amd64 --amend savonet/liquidsoap-ci-build:${TAG}_arm64 savonet/liquidsoap-ci-build:${TAG}_armhf
docker manifest push savonet/liquidsoap:$TAG

docker manifest create savonet/liquidsoap-alpine:$TAG --amend savonet/liquidsoap-ci-build:${TAG}_alpine_amd64 --amend savonet/liquidsoap-ci-build:${TAG}_alpine_arm64
docker manifest push savonet/liquidsoap-alpine:$TAG

docker login ghcr.io -u "$GHCR_USER" -p "$GHCR_PASSWORD"

docker manifest create ghcr.io/savonet/liquidsoap:$TAG --amend ghcr.io/savonet/liquidsoap-ci-build:${TAG}_amd64 --amend ghcr.io/savonet/liquidsoap-ci-build:${TAG}_arm64 savonet/liquidsoap-ci-build:${TAG}_armhf
docker manifest push ghcr.io/savonet/liquidsoap:$TAG

docker manifest create ghcr.io/savonet/liquidsoap-alpine:$TAG --amend ghcr.io/savonet/liquidsoap-ci-build:${TAG}_alpine_amd64 --amend ghcr.io/savonet/liquidsoap-ci-build:${TAG}_alpine_arm64
docker manifest push ghcr.io/savonet/liquidsoap-alpine:$TAG
