#!/bin/bash

GIT_HASH=$(git rev-parse --short=8 HEAD)
RELEASE=${PWD##*/}

mkdir -p /tmp/$RELEASE/$GIT_HASH
pushd _build/prod/rel/$RELEASE/
tar -zcvf /tmp/$RELEASE/$GIT_HASH/release.tar.gz .
popd

pushd packer/
packer build -var git_hash=$GIT_HASH -var release=$RELEASE packer.json
popd

rm -rf /tmp/$RELEASE/$GIT_HASH