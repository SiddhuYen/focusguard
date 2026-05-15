#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FocusGuard"
BUILD_DIR="$ROOT_DIR/.build"
CACHE_DIR="$BUILD_DIR/cache"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$CACHE_DIR/home" "$CACHE_DIR/clang" "$ROOT_DIR/dist"

cd "$ROOT_DIR"
HOME="$CACHE_DIR/home" \
CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang" \
swift build --disable-sandbox -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
sed \
  -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
  -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/app.focusguard.mvp/g" \
  -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/g" \
  -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g" \
  "$ROOT_DIR/App/Info.plist" > "$CONTENTS_DIR/Info.plist"

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
