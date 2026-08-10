#!/bin/sh
# Builds a universal (arm64 + x86_64) release binary for AquaFinderApp.
#
# Tries SwiftPM's native multi-arch flag first (`swift build --arch arm64
# --arch x86_64`), which since SwiftPM 5.6 lipos the two slices together
# automatically. Falls back to building each arch separately and combining
# them with `lipo` if the merged binary isn't where expected — confirmed
# working on this toolchain (Swift 5.9.2, CLT-only, no Xcode.app).
#
# Result is always left at .build/universal/AquaFinderApp for
# make-app-bundle.sh to pick up.

set -e

cd "$(dirname "$0")/.."

TARGET=AquaFinderApp
CONFIG=release
OUT_DIR=.build/universal
OUT_BIN="$OUT_DIR/$TARGET"

mkdir -p "$OUT_DIR"

echo "==> Trying SwiftPM native multi-arch build..."
if swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$TARGET" 2>/tmp/aquafinder-multiarch-build.log; then
    MERGED_BIN=".build/apple/Products/$CONFIG/$TARGET"
    if [ -f "$MERGED_BIN" ] && lipo -info "$MERGED_BIN" 2>/dev/null | grep -q "x86_64" && lipo -info "$MERGED_BIN" | grep -q "arm64"; then
        echo "==> Multi-arch build succeeded: $MERGED_BIN"
        cp "$MERGED_BIN" "$OUT_BIN"
        lipo -info "$OUT_BIN"
        exit 0
    else
        echo "==> Multi-arch build ran but merged binary not found/not fat at $MERGED_BIN — falling back."
    fi
else
    echo "==> Multi-arch build flag failed — falling back to manual dual-build + lipo."
    cat /tmp/aquafinder-multiarch-build.log || true
fi

echo "==> Building arm64 slice..."
swift build -c "$CONFIG" --arch arm64 --product "$TARGET"
ARM64_BIN=".build/arm64-apple-macosx/$CONFIG/$TARGET"

echo "==> Building x86_64 slice..."
swift build -c "$CONFIG" --arch x86_64 --product "$TARGET"
X86_64_BIN=".build/x86_64-apple-macosx/$CONFIG/$TARGET"

if [ ! -f "$ARM64_BIN" ] || [ ! -f "$X86_64_BIN" ]; then
    echo "error: expected per-arch binaries not found ($ARM64_BIN / $X86_64_BIN)" >&2
    exit 1
fi

echo "==> Combining with lipo..."
lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$OUT_BIN"
lipo -info "$OUT_BIN"
echo "==> Universal binary at $OUT_BIN"
