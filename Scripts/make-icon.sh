#!/bin/sh
# Converts Resources/AquaFinder.iconset (a standard macOS .iconset folder
# of PNGs at the required sizes: icon_16x16.png, icon_16x16@2x.png,
# icon_32x32.png, ... icon_512x512@2x.png) into Resources/AppIcon.icns.
#
# No artwork exists yet (Phase 0) — run this once icon PNGs are added.

set -e

cd "$(dirname "$0")/.."

ICONSET=Resources/AquaFinder.iconset
OUT=Resources/AppIcon.icns

if [ ! -d "$ICONSET" ] || [ -z "$(ls -A "$ICONSET" 2>/dev/null)" ]; then
    echo "error: $ICONSET is empty — add icon PNGs before running this script" >&2
    exit 1
fi

iconutil --convert icns "$ICONSET" --output "$OUT"
echo "==> Wrote $OUT"
