#!/bin/sh
# Check the SBOM against known vulnerabilities.
#
# READS THE SBOM, not the tree. The document that ships beside the artifact is
# the document that was scanned, so the two cannot disagree — scanning the tree
# separately would leave an SBOM nobody had checked and a report about something
# slightly different.
#
# THIS IS THE ONE STEP WHOSE ANSWER IS NOT A FUNCTION OF ITS INPUTS. Build the
# same source twice and you get the same artifact; scan the same artifact twice
# a month apart and you SHOULD get different answers, because the vulnerability
# database moved even though nothing about the artifact did.
#
# So it runs in its own stage, on its own image, with a network — and refreshes
# the database immediately before reading it. It used to run inside the hermetic
# build, against a database the prestart task had staged onto a read-only
# export. That cost 2.4 GB copied through every allocation to make a
# time-varying step look reproducible, and it made the answer as current as
# whenever prefetch last ran rather than as current as the release.
#
# Three ways to reach a database, in order of preference, because this script is
# also what a developer runs on a laptop:
#
#   SFD_SCAN_ONLINE   the scan stage: refresh, then scan. The current answer.
#   GRYPE_DB_CACHE_DIR pointing at a real directory: use what is staged and do
#                     not reach out. Kept for a caller that stages one, and for
#                     the laptop case below.
#   neither, off a machine: let grype manage its own cache like any other user.
#
# In a machine with no database and no permission to fetch one, this FAILS
# rather than reporting a clean scan, for the reason the whole file exists: an
# empty report and a clean report look identical to everything downstream.
#
# The report is an artifact. It is signed and published with everything else,
# because "what did we know about this release when we cut it" is a question
# asked months later, and the answer has to have been written down at the time.
SFD_STEP=scan
. "$(dirname "$0")/lib.sh"

# EVERY document `sbom` wrote, not the one it used to write. When an image was
# staged there are two — the tree and the image — and scanning only the first
# would leave the thing that actually ships unchecked while a report sat beside
# it saying the build was scanned. Each gets its own report, named after its
# SBOM so the pairing is readable in the artifact listing.
SBOMS=$(find "$ARTIFACTS" -maxdepth 1 -name 'sbom*.cdx.json' 2>/dev/null | sort)

[ -n "$SBOMS" ] || { warn "no SBOM in $ARTIFACTS — nothing to scan"; exit 0; }
require_tool grype || exit 0

if [ -n "${SFD_SCAN_ONLINE:-}" ]; then
  # The scan stage, which has a network precisely so that this can happen here
  # instead of hours earlier in a different task.
  #
  # A FAILED REFRESH IS NOT FATAL BY ITSELF. grype falls back to whatever cache
  # it already holds, and a scan against a database a few days old is worth far
  # more than no scan at all. What IS fatal is grype then writing no report,
  # which the `-s` check below catches for every SBOM — so a refresh failure
  # degrades the answer and cannot silently remove it.
  log "refreshing the vulnerability database"
  export GRYPE_DB_AUTO_UPDATE=true
  if ! grype db update; then
    warn "could not refresh the vulnerability database — scanning against whatever cache is present"
  fi
elif [ -n "${GRYPE_DB_CACHE_DIR:-}" ] && [ -d "${GRYPE_DB_CACHE_DIR}" ] \
     && [ -n "$(ls -A "${GRYPE_DB_CACHE_DIR}" 2>/dev/null)" ]; then
  log "using the staged vulnerability database at $GRYPE_DB_CACHE_DIR"
  export GRYPE_DB_AUTO_UPDATE=false
  export GRYPE_DB_VALIDATE_AGE=false
elif in_guest; then
  # Not "the prefetch task did not stage deps/grype-db" any more: nothing stages
  # it, by design. Reaching here means a machine was asked to scan without being
  # told it may fetch, and guessing either way would be worse than saying so.
  fail "no vulnerability database and no permission to fetch one — set SFD_SCAN_ONLINE on the scan stage, or stage a database at GRYPE_DB_CACHE_DIR"
else
  log "no staged database; grype will use or refresh its own local cache"
fi

# The gate is SEPARATE from the scan, and the scan itself never fails the build.
#
# A vulnerability found in a dependency is information; whether it should stop a
# release is policy, and policy that lives in a build script is policy nobody can
# review. SFD_SCAN_FAIL_ON names the severity that blocks, defaults to unset
# (report only), and the report is staged either way — so turning the gate on
# later does not change what was recorded, only what it costs.
#
# Blocking findings are COUNTED ACROSS EVERY REPORT and the failure comes after
# the loop, so a critical in the tree cannot stop the image from being scanned
# and recorded. Half a scan is the one outcome worth avoiding: it leaves an
# artifact set that looks audited and is not.
blocking=0

# A here-string, not `find | while read`: a pipeline runs the body in a subshell
# and a count incremented there would never reach the check below — the same
# defect sign.sh carries a comment about, for the same reason.
while IFS= read -r sbom; do
  [ -n "$sbom" ] || continue
  base=$(basename "$sbom" .cdx.json)          # sbom | sbom.image
  REPORT="$ARTIFACTS/vulnerabilities${base#sbom}.json"

  log "scanning $sbom"
  grype "sbom:$sbom" \
    --output "json=$REPORT" \
    --quiet \
    || scan_rc=$?

  [ -s "$REPORT" ] || fail "grype wrote no report for $sbom"

  if [ -n "${SFD_SCAN_FAIL_ON:-}" ] && have jq; then
    n=$(jq --arg s "$SFD_SCAN_FAIL_ON" \
          '[.matches[]? | select(.vulnerability.severity | ascii_downcase == ($s | ascii_downcase))] | length' \
          "$REPORT")
    blocking=$(( blocking + ${n:-0} ))
  fi

  if have jq; then
    log "wrote $REPORT ($(jq '.matches | length' "$REPORT") match(es))"
  else
    log "wrote $REPORT"
  fi
done <<EOF
$SBOMS
EOF

if [ "$blocking" -gt 0 ]; then
  fail "$blocking $SFD_SCAN_FAIL_ON vulnerability/vulnerabilities (see $ARTIFACTS/vulnerabilities*.json)"
fi
