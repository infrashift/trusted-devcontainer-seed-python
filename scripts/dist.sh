#!/bin/sh
# SFD-GOLDEN-DIVERGES: nothing is compiled, so there is no binary to stage. The
# devcontainer DEFINITION is staged instead, so that the build has something to
# sign and attest -- an attestation over an empty artifact set says nothing about
# what was published.
SFD_STEP=dist
. "$(dirname "$0")/lib.sh"

# $ARTIFACTS, from lib.sh -- the directory the Makefile exports and the runner
# collects. This script said ARTIFACT_OUT, a name nothing in the golden contract
# sets, and the first build the forge ran on this repository failed here with
# `ARTIFACT_OUT is not set' while every sibling script staged into $ARTIFACTS.
mkdir -p "$ARTIFACTS"

# The two files that DECIDE the image, and nothing else. Copying the whole
# .devcontainer directory would stage the entrypoint and the skeleton as
# artifacts, which are inputs to the image rather than descriptions of it.
cp .devcontainer/devcontainer.json "$ARTIFACTS/devcontainer.json"
cp .devcontainer/Containerfile "$ARTIFACTS/devcontainer.Containerfile"

log "staged the devcontainer definition in $ARTIFACTS"
