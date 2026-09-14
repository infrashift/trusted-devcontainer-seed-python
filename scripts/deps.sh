#!/bin/sh
# Fetch this repository's dependencies, so that every later step can run offline.
#
# THE ONLY GOLDEN STEP THAT IS SUPPOSED TO REACH THE NETWORK, and the only one
# that is not in `make all`. It runs in a PRESTART task, on the same toolchain
# machine that will later compile — networked here, hermetic there.
#
# WHY THE SAME MACHINE, which is the whole point of this file existing. The
# caches were populated by a separate Debian image that pinned its own Go, bun
# and uv versions, with a comment saying those versions "must track the build
# machines". They did not: it pinned go 1.25.3 while the machine shipped
# go1.26.4, and earlier it pinned grype 0.87.0 against the machine's 0.115.0 —
# which produced a green build through `sbom` and a failure on `scan`, because
# grype ties its database schema to the client. One machine doing both halves
# cannot disagree with itself, and deletes the rule along with the drift.
#
# NOTHING HERE IS BUILT. Fetch only: `go mod download`, `bun install
# --ignore-scripts`, `pip download`. A dependency that runs code at install time
# would be running it in the one task with a network, which is why the flags
# that stop that are not optional.
SFD_STEP=deps
. "$(dirname "$0")/lib.sh"

# Where the caches land. The forge points this at the allocation directory the
# build task later reads; a laptop gets ./deps and can inspect exactly what CI
# would hand over.
DEPS="${SFD_DEPS_OUT:-$PWD/deps}"
mkdir -p "$DEPS"

fetched=0

# --- Go -----------------------------------------------------------------------
#
# GOTOOLCHAIN=local for the same reason the build sets it: a go.mod naming a
# different toolchain would make Go DOWNLOAD one, and the cache handed over
# would then be built by a version the compile step does not have. That is the
# same drift this file exists to remove, arriving by a different route.
if [ -f go.mod ]; then
  if have go; then
    log "go: downloading modules"
    GOMODCACHE="$DEPS/go/pkg/mod" \
    GOPROXY="${SFD_GOPROXY:-https://proxy.golang.org,direct}" \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=mod \
      go mod download all || fail "go mod download failed"
    fetched=$((fetched + 1))
  else
    require_tool go || exit 0
  fi
fi

# --- JavaScript ---------------------------------------------------------------
#
# --ignore-scripts: an install script is arbitrary code from a dependency, and
# this is the networked task. --frozen-lockfile keeps resolution honest, but
# only when there is a lockfile to be frozen against.
for dir in . docs web; do
  [ -f "$dir/package.json" ] || continue
  if have bun; then
    frozen=""
    [ -f "$dir/bun.lock" ] && frozen="--frozen-lockfile"
    log "bun: populating the install cache for $dir/"
    BUN_INSTALL_CACHE_DIR="$DEPS/bun" \
    NPM_CONFIG_REGISTRY="${SFD_NPM_REGISTRY:-https://registry.npmjs.org}" \
      bun install --cwd "$dir" --ignore-scripts $frozen \
        || fail "bun install failed in $dir/"
    fetched=$((fetched + 1))
  else
    require_tool bun || exit 0
  fi
done

# --- Python -------------------------------------------------------------------
#
# A WHEELHOUSE rather than a resolver cache: the build then installs with
# PIP_NO_INDEX=1 and PIP_FIND_LINKS pointing here, which cannot reach out even
# by accident. Only requirements files are handled; a pyproject-only project
# would need its dependencies compiled to a requirements file first, and no
# repository in this org needs that yet.
for req in requirements.txt requirements-dev.txt; do
  [ -f "$req" ] || continue
  if have python3; then
    log "python: downloading wheels for $req"
    mkdir -p "$DEPS/wheels"
    python3 -m pip download \
      --index-url "${SFD_PYPI_INDEX:-https://pypi.org/simple}" \
      -r "$req" -d "$DEPS/wheels" || fail "pip download failed for $req"
    fetched=$((fetched + 1))
  else
    require_tool python3 || exit 0
  fi
done
if [ -f pyproject.toml ] && [ ! -f requirements.txt ]; then
  log "python: pyproject.toml with no requirements.txt — nothing staged"
fi

# NOT AN ERROR. A repository with no manifest of any kind has no dependencies to
# fetch, and most of this forge's repositories are single-module Go programs
# whose dependencies are already vendored or trivial. Failing here would make
# the prestart phase reject repositories that build perfectly well.
if [ "$fetched" -eq 0 ]; then
  log "no dependency manifest found — nothing to fetch"
else
  log "staged $fetched dependency set(s) into $DEPS"
fi
