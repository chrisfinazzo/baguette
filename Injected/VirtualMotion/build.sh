#!/bin/bash
# Build VirtualMotion.dylib — iOS-Simulator dylib that answers CoreMotion
# from the motion intent baguette publishes into /tmp/BaguetteMotion.json.
#
# Loaded into simulator-launched apps via DYLD_INSERT_LIBRARIES, armed by
# `SimctlSimulatorInjection` alongside VirtualCamera.dylib (they share the
# variable — see `InjectedDylibs`).
#
# Unlike VirtualCamera/, this is baguette-original code, so symbols carry a
# `VM` / `VirtualMotion` prefix rather than a vendored one.
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=VirtualMotion.dylib

# Fat, so it works on both Apple silicon and Intel hosts. The
# `-target …-simulator` triple is what stamps Mach-O LC_BUILD_VERSION
# platform=7 (iOS-Simulator), which the simulator's dyld requires.
build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -dynamiclib \
        -framework Foundation \
        -framework CoreMotion \
        -fobjc-arc \
        -Wall \
        -install_name "@rpath/${OUT}" \
        -Wl,-adhoc_codesign \
        -Wl,-headerpad_max_install_names \
        -I Sources \
        -o "VirtualMotion.${arch}.dylib" \
        Sources/VirtualMotionIntent.m \
        Sources/VirtualMotionFactory.m \
        Sources/VirtualMotionHooks.m
}

# Fat by default, so one dylib serves both Apple silicon and Intel hosts.
# `BAGUETTE_INJECTED_ARCHS` narrows that to a single slice, which is what
# Homebrew needs: `brew audit` rejects a keg containing a universal binary
# ("Unexpected universal binaries were found"), so its formula builds
# host-arch-only. One slice skips `lipo` — the slice *is* the product.
ARCHS=${BAGUETTE_INJECTED_ARCHS:-"arm64 x86_64"}

SLICES=()
for arch in $ARCHS; do
    build_slice "$arch"
    SLICES+=("${OUT%.dylib}.${arch}.dylib")
done

if [ "${#SLICES[@]}" -eq 1 ]; then
    mv "${SLICES[0]}" "$OUT"
else
    xcrun lipo -create "${SLICES[@]}" -output "$OUT"
    rm "${SLICES[@]}"
fi

# Modern `ld` ad-hoc signs each slice with the `linker-signed` flag set, and
# `lipo -create` preserves those signatures. iOS 26+ simulator dyld accepts
# `linker-signed` adhoc but REJECTS a post-build `codesign --force --sign -`
# with `code:codesigning(3) invalid-page(2)`. So we deliberately do NOT
# re-sign here — same rule as VirtualCamera/build.sh.

echo "Built: $(pwd)/$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Format|CodeDirectory|Signature" | head -3
