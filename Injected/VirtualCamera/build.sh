#!/bin/bash
# Build VirtualCamera.dylib — iOS-Simulator dylib that swizzles AVCapture*
# / UIImagePickerController inside the simulator process so iOS apps see
# frames baguette writes into the shared-memory ring buffer.
#
# Vendored from asc-pro/SimCam — see VENDORED_FROM.md. Internal symbols
# retain the `SimCam` prefix so we can re-sync upstream cleanly; the
# build artifact is renamed to make the role visible to baguette
# consumers ("the iOS simulator's virtual camera").
#
# Loaded into every simulator-launched app via DYLD_INSERT_LIBRARIES,
# armed by `SimctlSimulatorInjection`.
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=VirtualCamera.dylib

# Build a fat dylib so it works on both Apple silicon and Intel hosts.
# `-target ...-simulator` makes Mach-O LC_BUILD_VERSION platform=7
# (iOS-Simulator), which is what gets accepted by the simulator's dyld.
build_slice() {
    local arch="$1"
    xcrun clang \
        -arch "$arch" \
        -isysroot "$SDK" \
        -target "${arch}-apple-ios17.0-simulator" \
        -dynamiclib \
        -framework Foundation \
        -framework UIKit \
        -framework QuartzCore \
        -framework CoreGraphics \
        -framework AVFoundation \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework ImageIO \
        -framework CoreServices \
        -fobjc-arc \
        -ldl \
        -install_name "@rpath/${OUT}" \
        -Wl,-adhoc_codesign \
        -Wl,-headerpad_max_install_names \
        -I Sources \
        -o "VirtualCamera.${arch}.dylib" \
        Sources/SimCamInject.m \
        Sources/SimCamPreviewLayerDriver.m \
        Sources/SimCamFakePhoto.m \
        Sources/SimCamSharedFrameReader.m \
        Sources/SimCamVirtualCamera.m
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

# Modern `ld` ad-hoc signs each slice with the `linker-signed` flag set.
# `lipo -create` preserves those signatures. iOS 26+ simulator's dyld accepts
# `linker-signed` adhoc but REJECTS post-build `codesign --force --sign -`
# signatures with `code:codesigning(3) invalid-page(2)`. So we deliberately
# do NOT re-sign here.

echo "Built: $(pwd)/$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Format|CodeDirectory|Signature" | head -3
