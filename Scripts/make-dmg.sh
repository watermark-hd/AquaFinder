#!/bin/sh
# Builds a distributable AquaFinder.dmg from AquaFinder.app (drag-to-Applications
# layout). Run Scripts/build-universal.sh then Scripts/make-app-bundle.sh first.

set -e

cd "$(dirname "$0")/.."

APP_DIR="AquaFinder.app"
DMG_NAME="AquaFinder.dmg"
STAGING_DIR=".build/dmg-staging"

if [ ! -d "$APP_DIR" ]; then
    echo "error: $APP_DIR not found — run Scripts/make-app-bundle.sh first" >&2
    exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING_DIR" "$DMG_NAME"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating $DMG_NAME"
hdiutil create -volname "AquaFinder" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_NAME"

rm -rf "$STAGING_DIR"

echo "==> Done: $DMG_NAME"
