#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVELOPER_ID="${DEVSWEEP_DEVELOPER_ID:-}"
: "${DEVELOPER_ID:?Set DEVSWEEP_DEVELOPER_ID to your Developer ID Application identity}"

NOTARY_PROFILE="${DEVSWEEP_NOTARY_PROFILE:-}"
APPLE_ID="${DEVSWEEP_APPLE_ID:-}"
APPLE_PASSWORD="${DEVSWEEP_APPLE_PASSWORD:-}"
TEAM_ID="${DEVSWEEP_TEAM_ID:-}"
NOTARY_ARGS=()
if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?Set DEVSWEEP_APPLE_ID or DEVSWEEP_NOTARY_PROFILE}"
    : "${APPLE_PASSWORD:?Set DEVSWEEP_APPLE_PASSWORD or DEVSWEEP_NOTARY_PROFILE}"
    : "${TEAM_ID:?Set DEVSWEEP_TEAM_ID or DEVSWEEP_NOTARY_PROFILE}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID")
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
OUTPUT_DIR="${DEVSWEEP_OUTPUT_DIR:-$ROOT/.build/release}"
APP="$ROOT/DevSweep.app"
ZIP="$OUTPUT_DIR/DevSweep-$VERSION-macos.zip"

mkdir -p "$OUTPUT_DIR"
DEVSWEEP_ARCHS="${DEVSWEEP_ARCHS:-arm64 x86_64}" \
DEVSWEEP_DEVELOPER_ID="$DEVELOPER_ID" \
    "$ROOT/scripts/build_app.sh"

echo "==> Archiving signed app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notarization service"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-archiving stapled app"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Verifying final artifact"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose "$APP"
shasum -a 256 "$ZIP"

echo "Done."
echo "  App: $APP"
echo "  ZIP: $ZIP"
