#!/bin/sh

set -e

APK_FILE=$1
APK_DBG_FILE=$2
TAG=$3
USER=$4
PASSWORD=$5
ARCHITECTURE=$6

cp $APK_FILE $APK_DBG_FILE .

docker build --no-cache  --build-arg "APK_FILE=$APK_FILE" --build-arg "APK_DBG_FILE=$APK_DBG_FILE" -f .github/docker/Dockerfile.production-alpine -t savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE} .

docker login -u "$USER" -p "$PASSWORD" 

docker push savonet/liquidsoap-ci-build:${TAG}_alpine_${ARCHITECTURE}
