#!/bin/sh
# Build the container image and STAGE it as an OCI archive.
#
# STAGES. DOES NOT PUSH, for exactly the reason dist.sh does not upload: the
# credential that may write to the shared registry must not be reachable from
# build code. podman is perfectly capable of pushing -- `podman push' is in the
# same binary as `podman build' -- and this script must never call it: the
# forge's stage-contract.json asserts that at the source, and the machine this
# runs in holds no credential a push could use. The archive is collected from
# $ARTIFACTS by the runner and pushed by a poststop task holding a Nexus client
# that no developer and no repository has.
#
# THE BUILDER IS ROOTLESS PODMAN (since 2026-09-10; kaniko in a chroot before
# that). Inside the forge it runs as uid 1000 in a user namespace with a store
# under the allocation directory, resolves every FROM from the base images the
# warm stage staged (--pull=never: the machine has no credential and no route
# to a registry), and builds with --network none, enforced by the kernel. On a
# laptop it is the developer's own rootless podman, pulling normally.
#
# THIS TARGET HAS ITS OWN IMAGE IN THE FORGE: the OCI image machine, a stage of
# its own over the artifacts the compile stage already staged. That machine has
# no compiler on purpose, which is why `make image' there must not walk back to
# `build' (SFD_NO_REBUILD; see the Makefile).
#
# On a laptop, where one environment has everything, this is just another target
# in `make all'.
SFD_STEP=image
. "$(dirname "$0")/lib.sh"

CONTAINERFILE="${SFD_CONTAINERFILE:-Containerfile}"
[ -f "$CONTAINERFILE" ] || CONTAINERFILE=Dockerfile

# NOT AN ERROR. Most repositories in this forge produce binaries and nothing
# else, and `make all` runs every target for all of them. A repository without a
# Containerfile has simply not asked for an image, and failing here would make
# the golden workflow unusable for the majority to serve the minority.
if [ ! -f "$CONTAINERFILE" ]; then
  log "no Containerfile at the repository root — nothing to build"
  exit 0
fi

# Fatal in a machine, a warning on a laptop (lib.sh). Inside the forge a missing
# podman is not a missing dependency, it is the WRONG MACHINE, and the message
# has to say so: the alternative is a red build blaming a tool nobody chose to
# omit.
if ! have podman; then
  if in_guest; then
    fail "podman is not in this build machine.
       This target runs in the OCI image stage, which is the only image that
       carries the builder; a toolchain machine has none by design. Reaching
       here means the image stage was asked to run somewhere else, or that the
       stage's own image is not the one the jobspec named. See
       CONTAINER-CONTRACT.md."
  fi
  warn "podman is not installed — skipping this step locally (the forge will still run it)"
  exit 0
fi
for t in jq tar sha256sum; do
  have "$t" || fail "$t is required to stage an image and is not on PATH"
done

# ROOTLESS, AND uid 0 IS REFUSED INSIDE THE FORGE. podman as root takes the
# rootful code path and fails at its first mount without CAP_SYS_ADMIN -- the
# error names a mount, not the uid. A laptop's rootful podman is the
# developer's business.
if in_guest && [ "$(id -u)" = 0 ]; then
  fail "running as uid 0 in a build machine; rootless podman needs an unprivileged uid with subordinate ranges (the jobspec runs the image stage as 1000)"
fi

# THE BUILD CONTEXT IS THE REPOSITORY ROOT, and the staged binaries have to be
# reachable from inside it.
#
# On a laptop $ARTIFACTS already is ./dist/artifacts, so a Containerfile saying
# `COPY dist/artifacts/hello-api /hello-api` just works. Inside a build machine
# the staging directory is /sfdout/artifacts, which is outside the context — so
# it is mirrored to the same relative path first.
#
# Mirroring rather than moving: /sfdout is what the runner collects, and a build
# that emptied it would stage nothing and be reported as a build that produced
# no artifacts.
CTX_ARTIFACTS="$PWD/dist/artifacts"
if [ "$ARTIFACTS" != "$CTX_ARTIFACTS" ]; then
  log "mirroring staged artifacts into the build context at dist/artifacts"
  mkdir -p "$CTX_ARTIFACTS"
  cp -a "$ARTIFACTS/." "$CTX_ARTIFACTS/"
fi

IMAGE_NAME="${SFD_IMAGE_NAME:-$(basename "$PWD")}"
IMAGE_TAG="${SFD_REV:-dev}"
REF="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
ARCHIVE="$ARTIFACTS/image.oci.tar"
PLATFORM="${SFD_PLATFORM:-linux/amd64}"

# SOURCE_DATE_EPOCH comes from the commit being built, captured by the prestart
# task before it strips .git — by the time this runs there is no history left to
# read it from. Absent (a laptop, a dirty tree), fall back to a fixed epoch
# rather than the clock: a timestamp that moves is the single most common reason
# two builds of one revision disagree.
: "${SOURCE_DATE_EPOCH:=0}"
export SOURCE_DATE_EPOCH

# --- The warmed base images ---------------------------------------------------
#
# Inside the forge the image stage has NO NETWORK and NO CREDENTIAL, so every
# FROM other than scratch has to be in the store before the build starts. The
# warm stage staged each one as a `dir:' layout under $SFD_BASE_IMAGE_DIR --
# named by the digest hex, with a `.ref' beside it holding the FROM as the
# Containerfile spells it -- and `podman load' records the layout's manifest
# digest on the loaded image. Tagging it with the FROM's NAME (any tag; the
# digest is the identity) is what lets `FROM name@sha256:...' resolve out of
# the store under --pull=never. Measured on the workstation and the fleet:
# `dir:' keeps the served bytes, so the digest the Containerfile names is the
# digest the store holds.
#
# On a laptop there is no warm stage; SFD_BASE_IMAGE_DIR is unset, nothing is
# loaded, and podman pulls FROMs normally.
PULL_POLICY=missing
if [ -n "${SFD_BASE_IMAGE_DIR:-}" ] && [ -d "$SFD_BASE_IMAGE_DIR" ]; then
  loaded=0
  for reffile in "$SFD_BASE_IMAGE_DIR"/*.ref; do
    [ -f "$reffile" ] || continue
    hex=$(basename "$reffile" .ref)
    from=$(cat "$reffile")
    name="${from%%@*}"
    out=$(podman load -q -i "$SFD_BASE_IMAGE_DIR/$hex" 2>&1) \
      || fail "could not load the warmed base image for $from: $out"
    id=$(printf '%s' "$out" | sed -n 's/.*sha256:\([0-9a-f]\{64\}\).*/\1/p' | head -1)
    [ -n "$id" ] || fail "podman load reported no image id for $from: $out"
    podman tag "$id" "${name}:sfd-warm-${hex%${hex#??????????}}" \
      || fail "could not tag the warmed base image $id as $name"
    loaded=$((loaded + 1))
  done
  log "loaded $loaded warmed base image(s) from $SFD_BASE_IMAGE_DIR"
  PULL_POLICY=never
elif in_guest; then
  log "no warmed base images -- a Containerfile with a FROM other than scratch will fail (--pull=never)"
  PULL_POLICY=never
fi

# THE FLAGS, and why each one is here.
#
#   --pull=never            inside the forge: every FROM is resolved from the
#                           store the warm stage filled, and a pull would be a
#                           network fetch by a task that must not make one. On a
#                           laptop `missing', the ordinary policy.
#   --network none          ENFORCED, where kaniko was only told. A RUN that
#                           reaches for a registry or a package index fails
#                           here with the reason, rather than quietly building
#                           from the internet on one runtime and not the other.
#   --no-cache --layers=false
#                           no layer cache: the store is per allocation and
#                           starts empty, so every RUN layer is built from the
#                           recorded inputs anyway, and a squashed-to-nothing
#                           intermediate set is one less thing in the image.
#   --timestamp             the image's created time and every layer's mtimes
#                           set to SOURCE_DATE_EPOCH, so two builds of one
#                           revision write the same bytes. Passed as a FLAG
#                           with the variable UNSET for podman's own process:
#                           buildah >= 1.42 (podman 5.8) reads SOURCE_DATE_EPOCH
#                           from the environment and refuses --timestamp beside
#                           it (`timestamp and source-date-epoch would be
#                           ambiguous if allowed together' -- the first live
#                           build, 2026-09-10). One source of truth: the flag. Measured (Part 0 of
#                           the builder plan): identical manifest digest and
#                           identical layer blobs across two rounds, and no PAX
#                           atime/ctime records in the tars -- the pair that
#                           made envbuilder output irreproducible.
#   --identity-label=false  buildah otherwise stamps its own version into the
#                           config, and a podman bump would then change every
#                           image's digest without changing any image.
#   --platform              from var.build_platform, the same value the
#                           publisher records as `platform' in the attestation.
#   --isolation oci         the default for rootless podman, spelled: RUN steps
#                           run in a nested container with a real /proc, which
#                           is the whole reason the chroot builder was retired.
#
# THERE IS NO --push AND THERE MUST NEVER BE ONE; the machine holds no credential
# a push could use, and stage-contract.json refuses the token in this file.
log "building $REF from $CONTAINERFILE (pull=$PULL_POLICY, network none, platform $PLATFORM)"
env -u SOURCE_DATE_EPOCH podman build \
    --file "$CONTAINERFILE" \
    --tag "$REF" \
    --pull="$PULL_POLICY" \
    --network none \
    --no-cache \
    --layers=false \
    --timestamp "$SOURCE_DATE_EPOCH" \
    --identity-label=false \
    --platform "$PLATFORM" \
    --isolation oci \
    --quiet \
    . \
  || fail "podman failed to build $REF"

# --- Stage the layout ---------------------------------------------------------
#
# podman save --format oci-dir writes an OCI LAYOUT into a directory; the
# manifest digest is read from its index.json, and it is the value publish.sh
# copies into the attestation as `image_digest' -- what a challenge build
# compares its own round against. NEVER compare the archive's sha256 for that:
# tarring a directory has its own nondeterminism and would report drift that is
# not there.
OUT="${TMPDIR:-/tmp}/sfd-image-layout-$$"
rm -rf "$OUT"
podman save --format oci-dir -o "$OUT" "$REF" >/dev/null \
  || fail "podman save could not write an OCI layout for $REF"
[ -f "$OUT/index.json" ] || fail "podman save wrote no index.json"
digest1=$(jq -r '.manifests[0].digest // empty' "$OUT/index.json")
case "$digest1" in
  sha256:*) ;;
  *) fail "the layout's index names no sha256 manifest digest" ;;
esac
mfile="$OUT/blobs/${digest1%%:*}/${digest1#*:}"
[ -f "$mfile" ] || fail "the layout's manifest $digest1 is missing from blobs/"

# THE IMAGE MUST CONTAIN SOMETHING, and the digest agreeing proves nothing here.
#
# A --single-snapshot kaniko build once produced a 39-byte gzip of a zero-entry
# tar: the right ENTRYPOINT, the right port, a digest that reproduced perfectly,
# and no application in the image. cosign signed it, the attestation described
# it, ALLOW_ONCE made it immutable. Two empty layers are identical, so every
# reproducibility check certified it. The only proof is reading the layer, and
# 512 bytes separates "a file" from "nothing"; verify check 21 reads the same
# layer back from the registry.
largest=$(jq '[.layers[].size] | max // 0' "$mfile")
[ "$largest" -gt 512 ] \
  || fail "the largest layer of $REF is $largest bytes; the image is empty (a Containerfile that ADDs nothing, or a RUN that wrote nothing)"

# TAR, NOT `skopeo copy' AND NOT `podman save --format oci-archive'. An
# oci-archive is a tar of an OCI layout, and copying it through
# containers/image REWRITES the manifest into OCI media types where the source
# was docker-format -- measured: 05bf6e7d… became 0680159a…. podman's own tar
# writer makes no promise about member order or a leading `./' entry either.
# The flags are the reproducible-archive set, so the archive bytes are a
# function of the layout and nothing else — no mtimes, no uid, no readdir order.
#
# THE MEMBERS ARE NAMED, NOT `.', and that is not a style choice. Archiving a
# directory as `.' makes GNU tar write a leading "./" entry, and syft refuses
# the whole archive for it:
#
#   oci-archive: failed to visit tar entry="./" : potential path traversal
#   attack with entry: "./"
#
# skopeo reads such an archive quite happily -- which is how it passed the push
# and every digest check -- so the only thing that ever noticed was `make sbom',
# two targets later, reporting that syft failed on an archive that looked fine.
log "staging $REF as $ARCHIVE"
rm -f "$ARCHIVE"
(cd "$OUT" && tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner \
    -cf "$ARCHIVE" -- *) \
  || fail "could not write the OCI archive at $ARCHIVE"
[ -s "$ARCHIVE" ] || fail "wrote an empty archive at $ARCHIVE"
rm -rf "$OUT"

# A DESCRIPTION OF THE ARCHIVE, so the publish task never has to parse a
# filename to learn what it is pushing. Its absence is what "no image was built"
# looks like to that task, which is why it is written last and only on success.
#
# name/tag/archive/sha256 are the contract with publish.sh. `digest' is the
# manifest digest of the layout podman wrote, which publish.sh copies into the
# attestation as `image_digest': it is the value a challenge build compares
# against, and it is the layout's digest rather than the registry's because a
# challenge never pushes -- the two can differ when skopeo rewrites media types
# on the way in.
sum=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
cat > "$ARTIFACTS/image.json" <<JSON
{
  "name": "${IMAGE_NAME}",
  "tag": "${IMAGE_TAG}",
  "archive": "$(basename "$ARCHIVE")",
  "sha256": "${sum}",
  "digest": "${digest1}"
}
JSON

log "wrote $ARCHIVE ($digest1, largest layer $largest bytes) and $ARTIFACTS/image.json"
