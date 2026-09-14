#!/bin/sh
# Describe what was built, as CycloneDX JSON.
#
# The SBOM is an ARTIFACT: it is staged beside the binaries, digested with them,
# covered by the same cosign signature, and published with them. That is the
# point — a signature over a binary says the bytes are ours, and a signature over
# an SBOM naming those bytes says what is IN them.
#
# TWO DOCUMENTS WHEN THERE IS AN IMAGE, and they answer different questions. The
# tree SBOM says what this repository is made of; the image SBOM says what will
# actually be shipped, which includes everything the base image brought in and
# nothing the build discarded. Publishing only the first would describe a source
# tree while the registry served a container nobody had catalogued.
#
# Fully offline. syft reads the filesystem, the lockfiles and the archive; it
# needs no network, which is why this step can run inside a hermetic build
# machine at all.
SFD_STEP=sbom
. "$(dirname "$0")/lib.sh"

SBOM="$ARTIFACTS/sbom.cdx.json"
IMAGE_SBOM="$ARTIFACTS/sbom.image.cdx.json"
ARCHIVE="$ARTIFACTS/image.oci.tar"

require_tool syft || exit 0

log "cataloguing the source tree and build output"
syft scan dir:. \
  --output "cyclonedx-json=$SBOM" \
  --source-name "${SFD_PROJECT:-$(basename "$PWD")}" \
  --source-version "${SFD_REV:-unknown}" \
  --quiet \
  || fail "syft failed"

[ -s "$SBOM" ] || fail "syft wrote an empty SBOM"
log "wrote $SBOM"

# The image, if `make image` staged one. Reading the ARCHIVE rather than the
# built image in a local store keeps this honest: the archive is the artifact
# that gets pushed, so it is the one that has to be described.
if [ -f "$ARCHIVE" ]; then
  log "cataloguing the staged image archive"
  syft scan "oci-archive:$ARCHIVE" \
    --output "cyclonedx-json=$IMAGE_SBOM" \
    --source-name "${SFD_IMAGE_NAME:-$(basename "$PWD")}" \
    --source-version "${SFD_REV:-unknown}" \
    --quiet \
    || fail "syft failed on $ARCHIVE"

  [ -s "$IMAGE_SBOM" ] || fail "syft wrote an empty image SBOM"
  log "wrote $IMAGE_SBOM"
fi
