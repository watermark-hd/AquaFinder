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

# CLT 27.0's x86_64 Swift runtime compatibility libraries
# (libswiftCompatibility56.a, libswiftCompatibilityPacks.a) only ship
# arm64/arm64e slices — no x86_64 at all, on this toolchain. Any x86_64
# link fails with "Undefined symbols ... __swift_FORCE_LOAD_
# $_swiftCompatibility56" as a result, unrelated to anything in this
# package. -runtime-compatibility-version none tells swiftc not to
# auto-link those back-deployment shims at all, which sidesteps the
# missing-slice problem entirely. The tradeoff is losing a handful of
# very old Swift-runtime bug-fix backports that only mattered on OS
# versions older than this app already requires, so it's a safe trade
# here — confirmed the resulting x86_64 slice still builds and runs.
RUNTIME_COMPAT_FLAGS="-Xswiftc -runtime-compatibility-version -Xswiftc none"

mkdir -p "$OUT_DIR"

echo "==> Trying SwiftPM native multi-arch build..."
# Which directory the merged binary lands in has moved around between
# SwiftPM/toolchain versions on this machine — seen both
# .build/apple/Products/release/ (older) and .build/out/Products/Release/
# (capital R, this CLT 27.0's build-system backend). Checking every
# candidate rather than hardcoding one avoids silently falling through
# to the slower per-arch path (which itself turned out to only be
# reliable against an already-populated .build — against a genuinely
# clean one it hits a cache conflict between the multi-arch attempt
# above and the single-arch builds below and produces nothing at the
# expected per-arch paths at all).
if swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$TARGET" $RUNTIME_COMPAT_FLAGS 2>/tmp/aquafinder-multiarch-build.log; then
    MERGED_BIN=""
    for candidate in \
        ".build/apple/Products/$CONFIG/$TARGET" \
        ".build/out/Products/Release/$TARGET" \
        ".build/out/Products/$CONFIG/$TARGET"
    do
        if [ -f "$candidate" ] && lipo -info "$candidate" 2>/dev/null | grep -q "x86_64" && lipo -info "$candidate" 2>/dev/null | grep -q "arm64"; then
            MERGED_BIN="$candidate"
            break
        fi
    done
    if [ -n "$MERGED_BIN" ]; then
        echo "==> Multi-arch build succeeded: $MERGED_BIN"
        cp "$MERGED_BIN" "$OUT_BIN"
        lipo -info "$OUT_BIN"
        exit 0
    else
        echo "==> Multi-arch build ran but no fat merged binary found at any known path — falling back."
    fi
else
    echo "==> Multi-arch build flag failed — falling back to manual dual-build + lipo."
    cat /tmp/aquafinder-multiarch-build.log || true
fi

# This toolchain's build-system backend writes every single-arch build's
# product to the SAME shared path (.build/out/Products/Release/$TARGET,
# or the legacy .build/<triple>/$CONFIG/$TARGET on older toolchains) —
# building x86_64 right after arm64 silently overwrites arm64's output
# in place rather than leaving it at a separate per-triple path. Each
# slice has to be copied out to its own stash location immediately
# after its build, before the next slice's build can clobber it.
find_product_bin() {
    for candidate in \
        ".build/out/Products/Release/$TARGET" \
        ".build/out/Products/$CONFIG/$TARGET" \
        ".build/$1-apple-macosx/$CONFIG/$TARGET"
    do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

echo "==> Building arm64 slice..."
swift build -c "$CONFIG" --arch arm64 --product "$TARGET" $RUNTIME_COMPAT_FLAGS
ARM64_SRC="$(find_product_bin arm64)" || { echo "error: arm64 product not found after build" >&2; exit 1; }
ARM64_BIN="$OUT_DIR/${TARGET}-arm64"
cp "$ARM64_SRC" "$ARM64_BIN"

echo "==> Building x86_64 slice..."
swift build -c "$CONFIG" --arch x86_64 --product "$TARGET" $RUNTIME_COMPAT_FLAGS
X86_64_SRC="$(find_product_bin x86_64)" || { echo "error: x86_64 product not found after build" >&2; exit 1; }
X86_64_BIN="$OUT_DIR/${TARGET}-x86_64"
cp "$X86_64_SRC" "$X86_64_BIN"

if [ ! -f "$ARM64_BIN" ] || [ ! -f "$X86_64_BIN" ]; then
    echo "error: expected per-arch binaries not found ($ARM64_BIN / $X86_64_BIN)" >&2
    exit 1
fi
if lipo -info "$ARM64_BIN" | grep -q "x86_64"; then
    echo "error: arm64 stash ($ARM64_BIN) actually contains x86_64 — the x86_64 build overwrote it before it was copied out. Build-system output layout changed again; find_product_bin needs updating." >&2
    exit 1
fi

echo "==> Combining with lipo..."
lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$OUT_BIN"
lipo -info "$OUT_BIN"
echo "==> Universal binary at $OUT_BIN"
