#!/bin/bash
# Build SpikeNet.dylib — mirrors VirtualMotion/build.sh exactly (same triple,
# same adhoc linker signature, no post-build codesign).
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=SpikeNet.dylib

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
        -o "SpikeNet.${arch}.dylib" \
        Sources/SpikeNet.m
}

build_slice arm64
build_slice x86_64
xcrun lipo -create SpikeNet.arm64.dylib SpikeNet.x86_64.dylib -output "$OUT"
rm SpikeNet.arm64.dylib SpikeNet.x86_64.dylib
echo "Built: $(pwd)/$OUT"
