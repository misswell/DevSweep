#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/DevSweep.app"
ARCH_LIST="${DEVSWEEP_ARCHS:-$(uname -m)}"
ARCHS=(${=ARCH_LIST})

cd "$PROJECT_DIR"

DEVELOPER_ID="${DEVSWEEP_DEVELOPER_ID:-}"
ALLOW_ADHOC="${DEVSWEEP_ALLOW_ADHOC:-0}"
if [[ -z "$DEVELOPER_ID" && "$ALLOW_ADHOC" != "1" ]]; then
    echo "DEVSWEEP_DEVELOPER_ID is required for distributable builds." >&2
    echo "Set DEVSWEEP_ALLOW_ADHOC=1 only for local development builds." >&2
    exit 1
fi

MAIN_BINARIES=()
UPDATER_BINARIES=()
SCRATCH_DIRS=()

for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64|x86_64) ;;
        *)
            echo "Unsupported architecture: $arch (use arm64 and/or x86_64)" >&2
            exit 1
            ;;
    esac

    scratch_path="$PROJECT_DIR/.build-devsweep-$arch"
    SCRATCH_DIRS+=("$scratch_path")
    triple="${arch}-apple-macosx13.0"
    swift build -c release --triple "$triple" --scratch-path "$scratch_path"
    bin_path="$(swift build -c release --triple "$triple" --scratch-path "$scratch_path" --show-bin-path)"
    MAIN_BINARIES+=("$bin_path/DevSweep")
    UPDATER_BINARIES+=("$bin_path/DevSweepUpdater")
done

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

if [[ "${#MAIN_BINARIES[@]}" == 1 ]]; then
    cp "${MAIN_BINARIES[1]}" "$APP_PATH/Contents/MacOS/DevSweep"
    cp "${UPDATER_BINARIES[1]}" "$APP_PATH/Contents/MacOS/DevSweepUpdater"
else
    lipo -create "${MAIN_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/DevSweep"
    lipo -create "${UPDATER_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/DevSweepUpdater"
fi

cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/DevSweep.icns" "$APP_PATH/Contents/Resources/DevSweep.icns"
chmod +x "$APP_PATH/Contents/MacOS/DevSweep" "$APP_PATH/Contents/MacOS/DevSweepUpdater"

if [[ -n "$DEVELOPER_ID" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
        "$APP_PATH/Contents/MacOS/DevSweepUpdater"
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_PATH"
else
    codesign --force --sign - "$APP_PATH/Contents/MacOS/DevSweepUpdater"
    codesign --force --sign - "$APP_PATH"
fi

codesign --verify --deep --strict "$APP_PATH"

if [[ -n "$DEVELOPER_ID" ]]; then
    EXPECTED_TEAM_ID="${DEVSWEEP_DEVELOPER_TEAM_ID:-U8U443D7ZL}"
    for signed_path in \
        "$APP_PATH/Contents/MacOS/DevSweepUpdater" \
        "$APP_PATH"; do
        signature_details="$(codesign --display --verbose=4 "$signed_path" 2>&1)"
        if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
            echo "Expected a Developer ID Application signature: $signed_path" >&2
            exit 1
        fi
        if ! grep -q "^TeamIdentifier=$EXPECTED_TEAM_ID$" <<<"$signature_details"; then
            echo "Unexpected signing team for $signed_path (expected $EXPECTED_TEAM_ID)" >&2
            exit 1
        fi
    done
fi

for scratch_path in "${SCRATCH_DIRS[@]}"; do
    rm -rf "$scratch_path"
done

echo "Built: $APP_PATH"
echo "Architectures: ${ARCHS[*]}"
echo "Updater: $APP_PATH/Contents/MacOS/DevSweepUpdater"
