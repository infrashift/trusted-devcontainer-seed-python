#!/bin/sh
# SFD-GOLDEN-DIVERGES: a devcontainer repository compiles nothing; the golden
# build.sh fails when it recognises no project at the root, and here there is
# deliberately none.
#
# WHAT THIS REPOSITORY PRODUCES is an image, and it is not produced by the
# `image' stage either: envbuilder builds .devcontainer/devcontainer.json in its
# own stage, on a dispatch that asked for machine=devcontainer. So every target
# in the golden workflow is a no-op here except the ones that VALIDATE what will
# be built.
#
# The Makefile is still required and still runs. sfd-build-agent refuses a
# repository with no root Makefile, in fetch-deps and in build, before the
# poststop chain runs at all -- so "this repository has nothing to compile" has
# to be said in a script rather than by omitting one.
SFD_STEP=build
. "$(dirname "$0")/lib.sh"

log "devcontainer repository: nothing to compile"

# VALIDATED HERE RATHER THAN AT BUILD TIME, because the alternative is finding
# out inside a chroot in a poststop task. A devcontainer.json that is not JSON
# fails envbuilder after the base image has been pulled and unpacked, with a
# parse error attributed to the builder.
[ -f .devcontainer/devcontainer.json ] \
  || fail "no .devcontainer/devcontainer.json — this repository is built by envbuilder and there is nothing for it to build"

if command -v jq >/dev/null 2>&1; then
  jq -e . .devcontainer/devcontainer.json >/dev/null \
    || fail ".devcontainer/devcontainer.json is not valid JSON"
  # A `build.dockerfile' that names a file which is not there produces the same
  # late failure, one stage further in.
  df=$(jq -r '.build.dockerfile // empty' .devcontainer/devcontainer.json)
  if [ -n "$df" ]; then
    [ -f ".devcontainer/${df#./}" ] \
      || fail "devcontainer.json names build.dockerfile ${df}, which does not exist"
  fi
  log "devcontainer.json parses; $(jq -r '.features // {} | length' .devcontainer/devcontainer.json) feature(s) declared"
else
  log "jq not present — skipping the devcontainer.json checks"
fi
