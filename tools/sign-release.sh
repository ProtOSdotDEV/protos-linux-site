#!/bin/bash
# sign-release.sh <image-file> <version> <version-code>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECKEY="${PROTOS_SECKEY:-$HOME/.protos-keys/protos-release.key}"
GH_REPO="${PROTOS_GH_REPO:-ProtOSdotDEV/protos-linux-site}"
MANIFEST="$REPO_ROOT/api/v1/manifest.json"
CHANNEL="${PROTOS_CHANNEL:-stable}"
EXPIRY_DAYS=30

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: $0 <image-file> <version> <version-code>"
IMAGE="$1"; VERSION="$2"; VERSION_CODE="$3"

[ -f "$IMAGE" ] || die "No such image: $IMAGE"
[ -f "$SECKEY" ] || die "No signing key at $SECKEY (set \$PROTOS_SECKEY)"
command -v minisign >/dev/null || die "minisign not installed (brew install minisign)"
command -v gh >/dev/null       || die "gh not installed"
echo "$VERSION_CODE" | grep -qE '^[0-9]+$' || die "version-code must be a positive integer"

if [ -f "$MANIFEST" ]; then
  PREV=$(jq -r '.latest.version_code // 0' "$MANIFEST" 2>/dev/null || echo 0)
  [ "$VERSION_CODE" -gt "$PREV" ] || die "version-code $VERSION_CODE must be > current $PREV"
fi

WORK="$(mktemp -d)"
 trap 'rm -rf "$WORK"' EXIT

ARTIFACT="protos-${VERSION}-arm64.img.zst"
echo "[*] Compressing -> $ARTIFACT"
zstd -19 -T0 --long -f "$IMAGE" -o "$WORK/$ARTIFACT" 2>&1 | tail -1

SIZE=$(wc -c < "$WORK/$ARTIFACT" | tr -d ' ')
SHA=$(shasum -a 256 "$WORK/$ARTIFACT" | awk '{print $1}')
echo "[*] size=$SIZE sha256=$SHA"

minisign -S -s "$SECKEY" -m "$WORK/$ARTIFACT" \
         -t "protos-update v=$VERSION code=$VERSION_CODE sha256=$SHA"

TAG="v$VERSION"
BASE="https://github.com/$GH_REPO/releases/download/$TAG"

echo "[*] Creating GitHub release $TAG"
gh release create "$TAG" \
  "$WORK/$ARTIFACT" "$WORK/$ARTIFACT.minisig" \
  --repo "$GH_REPO" --title "ProtOS $VERSION" \
  --notes "ProtOS $VERSION (version_code $VERSION_CODE)" 2>&1 | tail -2

jq -n \
  --argjson schema 1 \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg expires "$(date -u -v+${EXPIRY_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "+${EXPIRY_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)" \
  --arg channel "$CHANNEL" \
  --arg version "$VERSION" \
  --argjson version_code "$VERSION_CODE" \
  --arg released "$(date -u +%Y-%m-%d)" \
  --arg url "$BASE/$ARTIFACT" \
  --arg sig_url "$BASE/$ARTIFACT.minisig" \
  --argjson size "$SIZE" \
  --arg sha256 \
  '{schema:$schema, generated:$generated, expires:$expires, channel:$channel,
    latest:{version:$version, version_code:$version_code, released:$released,
            image:{url:$url, sig_url:$sig_url, size:$size, sha256:$sha256}}}' \
  > "$MANIFEST"

minisign -S -s "$SECKEY" -m "$MANIFEST" -t "protos-manifest channel=$CHANNEL code=$VERSION_CODE"

echo
echo "[+] Released $VERSION (code $VERSION_CODE)"
echo "    git add api/v1/manifest.json api/v1/manifest.json.minisig && git commit -m 'release $VERSION' && git push"
