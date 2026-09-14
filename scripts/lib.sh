#!/bin/sh
# Shared helpers for the golden workflow scripts.
#
# Sourced, never executed. Every script here runs under `sh` in a Guix microVM
# with no network and no bash, so: POSIX only, no arrays, no [[ ]], no pipefail.
# A bashism works on a laptop and fails inside the guest with a message that
# blames the build rather than the shell.
set -eu

log()  { echo "[$SFD_STEP] $*"; }
warn() { echo "[$SFD_STEP] WARNING: $*" >&2; }
fail() { echo "[$SFD_STEP] ERROR: $*" >&2; exit 1; }

# Artifacts stage here. Defaulted rather than required so a developer can run any
# single script directly without setting up the environment make provides.
SFD_OUT="${SFD_OUT:-$PWD/dist}"
ARTIFACTS="${ARTIFACTS:-$SFD_OUT/artifacts}"

# Are we inside a forge build machine, or on somebody's laptop?
#
# /sfdout is the staging directory a build machine provides and a laptop does
# not. In the microVM runtime it is the 9p export the guest mounts; in the
# container runtime the agent creates it before running make, precisely so this
# one question keeps one answer and these scripts need no knowledge of which
# runtime they landed in.
#
# This is what lets one script be strict where strictness is possible — offline,
# deterministic, no toolchain downloads — and forgiving where a developer would
# otherwise be blocked by a missing tool.
#
# The name is historical: it said "guest" when a VM was the only machine there
# was. Everything that reads it means "in a build machine".
in_guest() { [ -d /sfdout ]; }

have() { command -v "$1" >/dev/null 2>&1; }

# A tool the workflow needs.
#
# Inside the guest a missing tool is FATAL: the image is a pinned Guix closure,
# so anything absent is a mistake in the image definition and silently skipping
# the step would produce a build that looks complete and shipped no SBOM.
#
# On a laptop it is a warning and the step is skipped, because the point of
# these targets running locally is fast feedback, and refusing to build until
# somebody installs syft is not that.
require_tool() {
  if have "$1"; then
    return 0
  fi
  if in_guest; then
    fail "$1 is not in the build image, and the workflow needs it"
  fi
  warn "$1 is not installed — skipping this step locally (the forge will still run it)"
  return 1
}

mkdir -p "$ARTIFACTS"
