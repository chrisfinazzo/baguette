#!/bin/bash
# Build VirtualNetwork.dylib — iOS-Simulator dylib that conditions an app's
# own URLSession traffic from the condition baguette publishes into
# /tmp/BaguetteNetwork.json.
#
# Loaded into simulator-launched apps via DYLD_INSERT_LIBRARIES, armed by
# `SimctlSimulatorInjection` alongside VirtualCamera.dylib and
# VirtualMotion.dylib (all three share the variable — see `InjectedDylibs`).
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=VirtualNetwork.dylib

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
        -fobjc-arc \
        -Wall \
        -install_name "@rpath/${OUT}" \
        -Wl,-adhoc_codesign \
        -I Sources \
        -o "VirtualNetwork.${arch}.dylib" \
        Sources/VirtualNetworkCondition.m \
        Sources/VirtualNetworkProtocol.m \
        Sources/VirtualNetworkWebSocket.m \
        Sources/VirtualNetworkHooks.m
}

build_slice arm64
build_slice x86_64

xcrun lipo -create \
    VirtualNetwork.arm64.dylib \
    VirtualNetwork.x86_64.dylib \
    -output "$OUT"

rm VirtualNetwork.arm64.dylib VirtualNetwork.x86_64.dylib

# Modern `ld` ad-hoc signs each slice with the `linker-signed` flag set, and
# `lipo -create` preserves those signatures. iOS 26+ simulator dyld accepts
# `linker-signed` adhoc but REJECTS a post-build `codesign --force --sign -`
# with `code:codesigning(3) invalid-page(2)`. So we deliberately do NOT
# re-sign here — same rule as VirtualCamera/build.sh and VirtualMotion/build.sh.

echo "Built: $(pwd)/$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Format|CodeDirectory|Signature" | head -3
