#!/bin/bash
# verify-release.sh <image.zst> <image.zst.minisig> [installed-version-code]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBKEY="${PROTOS_PUBKEY:-$REPO_ROOT/api/v1/protos-release.pub}"

die() { echo  "REJECT:  $*" >&2; exit 1; }
pass() { echo "   OK:   $*"; }

[ $# -ge 2 ] || { echo "usage: $0 <image> <sig> [installed-version-code]"; exit 1; }
IMAGE="$1"; SIG="$2"; INSTALLED_CODE="${3:-0}"

[ -f "$IMAGE" ]   || die "no image: $IMAGE"
[ -f "$SIG" ]     || die "no signature: $SIG"
[ -f "$PUBKEY" ]  || die "no public key at $PUBKEY"

echo "Verifying $(basename "$IMAGE")..."

# on the device this key is burned in at manufacture, never fetched.
OUT=$(minisign -V -p "$PUBKEY" -m "$IMAGE" 2>&1) ||
die "signature invalid, discarding"
pass "signature valid"

TRUSTED=$(printf '%s\n' "$OUT" | sed -n 's/^Trusted comment: //p')
[ -n "$TRUSTED" ] || die "no trusted comment, version not bound to image"
pass "trusted comment: $TRUSTED"

NEW_CODE=$(printf '%s\n' "$TRUSTED" | sed -n 's/.*code=\([0-9]*\).*/\1/p')
[ -n "$NEW_CODE" ] || die "no version code in trusted comment"
[ "$NEW_CODE" -gt "$INSTALLED_CODE" ] \
  || die "rollback blocked: offered $NEW_CODE <= installed $INSTALLED_CODE"
pass "anti-rollback: $INSTALLED_CODE -> $NEW_CODE"

CLAIMED_SHA=$(printf '%s\n' "$TRUSTED" | sed -n 's/.*sha256=\([a-f0-9]*\).*/\1/p')
if [ -n "$CLAIMED_SHA" ]; then
  ACTUAL_SHA=$(shasum -a 256 "$IMAGE" | awk '{print $1}')
  [ "$CLAIMED_SHA" = "$ACTUAL_SHA" ] || die "sha256 mismatch, refusing to verify"
  pass "sha256 matched signed value"
fi

echo
echo "ACCEPT: version code $NEW_CODE is authentic and newer. Safe to flash"