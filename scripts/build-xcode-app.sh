#!/usr/bin/env bash
# Builds dist/FocusGuard.app, signed with the Apple Development identity configured in the
# project (team 49JBT7CMG9). A stable signature is what lets macOS keep the Accessibility
# and Automation grants across rebuilds: TCC keys them to the designated requirement, so
# ad-hoc signing (a new hash every build) drops them every time.
#
#   ./scripts/build-xcode-app.sh                  # signed, hardened runtime
#   FOCUSGUARD_TEAM_ID=OTHERTEAM ./scripts/...    # override the team
#   FOCUSGUARD_ADHOC=1 ./scripts/...              # unsigned fallback, drops TCC grants
#
# The first signed build asks for the login keychain password; choose "Always Allow".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/FocusGuard.app"

cd "$ROOT_DIR"

args=(
  -project FocusGuard.xcodeproj
  -scheme FocusGuard
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_DIR"
  -destination 'platform=macOS'
)

if [ "${FOCUSGUARD_ADHOC:-0}" = "1" ]; then
  echo "warning: building ad-hoc. macOS will drop Accessibility and Automation grants." >&2
  xcodebuild "${args[@]}" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
  codesign --force --sign - "$APP_PATH"
else
  args+=(-allowProvisioningUpdates)
  [ -n "${FOCUSGUARD_TEAM_ID:-}" ] && args+=(DEVELOPMENT_TEAM="$FOCUSGUARD_TEAM_ID")
  xcodebuild "${args[@]}" build
fi

rm -rf "$ROOT_DIR/dist/FocusGuard.app"
mkdir -p "$ROOT_DIR/dist"
cp -R "$APP_PATH" "$ROOT_DIR/dist/FocusGuard.app"

echo "Built $ROOT_DIR/dist/FocusGuard.app"
codesign -dv "$ROOT_DIR/dist/FocusGuard.app" 2>&1 | grep -E "Identifier|TeamIdentifier|flags" || true
