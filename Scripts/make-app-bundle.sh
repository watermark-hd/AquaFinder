#!/bin/sh
# Assembles AquaFinder.app from the universal binary produced by
# build-universal.sh, then code-signs it. No Apple Developer Program
# enrollment or notarization involved (personal use across two Macs only).
#
# Signs with the local self-signed "AquaFinder Local Dev" identity when
# it's present in the login keychain, falling back to ad-hoc (`-`)
# otherwise (e.g. on the other Mac, which doesn't have that identity
# installed). A stable identity matters because macOS ties folder-access
# (TCC) grants to the code signature — ad-hoc signing gets a new identity
# every rebuild, so the app forgets Desktop/Documents/Downloads access
# and re-prompts each time; signing with the same identity every build
# keeps those grants across rebuilds.

set -e

cd "$(dirname "$0")/.."

APP_NAME=AquaFinder
BIN_PATH=".build/universal/AquaFinderApp"
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

echo "==> Copying localizations"
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP_DIR/Contents/Resources/"
done

SIGN_IDENTITY="AquaFinder Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> \"$SIGN_IDENTITY\" identity not found on this Mac — falling back to ad-hoc signing"
    echo "    (folder-access permissions will need re-granting after every rebuild on this Mac)"
    SIGN_IDENTITY="-"
fi

echo "==> Code signing ($SIGN_IDENTITY)"
codesign --deep --force --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Verifying"
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign -dv --verbose=4 "$APP_DIR" 2>&1 | grep -E "Signature|Identifier"

echo "==> Done: $APP_DIR"
