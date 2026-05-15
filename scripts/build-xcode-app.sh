#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
CONFIGURATION="Release"

cd "$ROOT_DIR"

xcodebuild \
  -project FocusGuard.xcodeproj \
  -scheme FocusGuard \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/FocusGuard.app"
codesign --force --sign - "$APP_PATH"

rm -rf "$ROOT_DIR/dist/FocusGuard.app"
mkdir -p "$ROOT_DIR/dist"
cp -R "$APP_PATH" "$ROOT_DIR/dist/FocusGuard.app"

echo "Built $ROOT_DIR/dist/FocusGuard.app"
