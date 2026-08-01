#!/bin/sh
# Assembles ClassicFinder.app from the universal binary produced by
# build-universal.sh, then ad-hoc code-signs it. No Apple Developer Program
# enrollment or notarization involved (personal use across two Macs only).

set -e

cd "$(dirname "$0")/.."

APP_NAME=ClassicFinder
BIN_PATH=".build/universal/ClassicFinderApp"
APP_DIR="$APP_NAME.app"

if [ ! -f "$BIN_PATH" ]; then
    echo "error: $BIN_PATH not found — run Scripts/build-universal.sh first" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cp Resources/Info.plist.template "$APP_DIR/Contents/Info.plist"

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "==> (no Resources/AppIcon.icns yet — app will use the generic icon; run Scripts/make-icon.sh once artwork exists)"
fi

echo "==> Ad-hoc code signing"
codesign --deep --force --sign - "$APP_DIR"

echo "==> Verifying"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign -dv --verbose=4 "$APP_DIR" 2>&1 | grep -E "Signature|Identifier"

echo "==> Done: $APP_DIR"
