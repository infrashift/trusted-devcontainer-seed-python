#!/bin/sh
# SFD-GOLDEN-DIVERGES: there is no code to test in a devcontainer repository.
# What can be checked without building is that every image reference is pinned,
# which is the property a trusted template exists to provide.
SFD_STEP=test
. "$(dirname "$0")/lib.sh"

command -v jq >/dev/null 2>&1 || { log "jq not present — skipping"; exit 0; }

# EVERY FEATURE BY DIGEST, NOT BY TAG. A tag can be moved; a digest cannot. The
# published template pins all nine, so an unpinned one here means somebody
# edited a reference by hand -- and the failure it prevents is silent: the
# workspace builds, works, and is not the thing that was reviewed.
unpinned=$(jq -r '.features // {} | keys[]' .devcontainer/devcontainer.json \
  | grep -v '@sha256:' || true)
[ -z "$unpinned" ] || fail "feature references are not digest-pinned:
$unpinned"

base=$(grep -m1 '^FROM ' .devcontainer/Containerfile 2>/dev/null || true)
case "$base" in
  *@sha256:*) ;;
  "") fail "no FROM line in .devcontainer/Containerfile" ;;
  *) fail "the base image is not digest-pinned: $base" ;;
esac

log "every image reference is digest-pinned"

# BOOTSTRAP IS DECLARED FIRST. Every trusted feature execs
# /opt/bootstrap/run-feature.sh, which only the bootstrap feature installs. The
# Dev Container CLI installs features in DECLARATION order (respecting
# installsAfter and overrideFeatureInstallOrder), so the first key in the map
# is the first RUN. (envbuilder, which built these until 2026-09-10, sorted the
# references as strings instead; the `ghcr.io:443/' spelling that worked
# around that is gone with it.)
first=$(jq -r '.features // {} | keys_unsorted | .[0]' .devcontainer/devcontainer.json)
case "$first" in
  */bootstrap@sha256:*) ;;
  *) fail "the first declared feature is not bootstrap but ${first}; every other feature execs /opt/bootstrap/run-feature.sh, which only bootstrap installs" ;;
esac
log "bootstrap is the first declared feature"

# EVERY ForceCommand IN sshd_config IS A FILE THE CONTAINERFILE INSTALLS. The
# two are a contract split across two files, and a wrapper named in one and not
# copied by the other is a workspace that builds, deploys, passes its `sshd
# listening' check and refuses every login with `No such file or directory'.
# That is how the first one shipped.
for fc in $(sed -n 's/^ForceCommand[[:space:]]\+\([^[:space:]]*\).*/\1/p' .devcontainer/config/sshd_config); do
  grep -Eq "^COPY .*[[:space:]]${fc}([[:space:]]|\$)" .devcontainer/Containerfile \
    || fail "sshd_config names ForceCommand ${fc} but .devcontainer/Containerfile installs nothing at that path"
done
log "every ForceCommand in sshd_config is installed by the Containerfile"
