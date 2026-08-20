#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_DIR/DevSweep.app"

cd "$PROJECT_DIR"
swift build -c release

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$PROJECT_DIR/.build/release/DevSweep" "$APP_PATH/Contents/MacOS/DevSweep"
cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

chmod +x "$APP_PATH/Contents/MacOS/DevSweep"
codesign --force --deep --sign - "$APP_PATH" >/dev/null
echo "Built: $APP_PATH"
