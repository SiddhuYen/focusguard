#!/usr/bin/env bash
# Builds dist/FocusGuard.app.
#
# Signing: ad-hoc by default, which is why macOS drops the Accessibility and Automation
# grants on every rebuild (TCC keys them to the code signature). Once you have an Apple
# Development certificate, export your team ID and the grants start surviving rebuilds:
#
#   FOCUSGUARD_TEAM_ID=ABCDE12345 ./scripts/build-xcode-app.sh
#
# Find the team ID with: security find-identity -v -p codesigning
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/FocusGuard.app"

cd "$ROOT_DIR"

if [ -n "${FOCUSGUARD_TEAM_ID:-}" ]; then
  xcodebuild \
    -project FocusGuard.xcodeproj \
    -scheme FocusGuard \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination 'platform=macOS' \
    -allowProvisioningUpdates \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$FOCUSGUARD_TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="-o runtime" \
    build
else
  echo "warning: no FOCUSGUARD_TEAM_ID set, falling back to ad-hoc signing." >&2
  echo "         Accessibility and Automation grants will be dropped on every build." >&2
  xcodebuild \
    -project FocusGuard.xcodeproj \
    -scheme FocusGuard \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    build
  codesign --force --sign - "$APP_PATH"
fi

rm -rf "$ROOT_DIR/dist/FocusGuard.app"
mkdir -p "$ROOT_DIR/dist"
cp -R "$APP_PATH" "$ROOT_DIR/dist/FocusGuard.app"

echo "Built $ROOT_DIR/dist/FocusGuard.app"
codesign -dv "$ROOT_DIR/dist/FocusGuard.app" 2>&1 | grep -E "Signature|TeamIdentifier|flags" || true
