#!/bin/bash
set -e
cd "$(dirname "$0")"

# The iOS-Simulator side of the camera feature — see VirtualCamera/.
# Cross-compiled against the iphonesimulator SDK (fat: arm64 + x86_64),
# linker-signed adhoc. Staged into Sources/Baguette/Resources/VirtualCamera/
# so SPM bundles it as a `.copy` resource.
./VirtualCamera/build.sh
mkdir -p Sources/Baguette/Resources/VirtualCamera
cp -f VirtualCamera/VirtualCamera.dylib Sources/Baguette/Resources/VirtualCamera/

# The iOS-Simulator side of the motion feature — see VirtualMotion/. Same
# shape as the camera dylib above: cross-compiled fat, linker-signed adhoc,
# staged for SPM to bundle. Both are armed through one shared
# DYLD_INSERT_LIBRARIES (see `InjectedDylibs`).
./VirtualMotion/build.sh
mkdir -p Sources/Baguette/Resources/VirtualMotion
cp -f VirtualMotion/VirtualMotion.dylib Sources/Baguette/Resources/VirtualMotion/

# The iOS-Simulator side of network conditioning — see VirtualNetwork/.
# Third dylib, same shape as the two above; all three are armed through one
# shared DYLD_INSERT_LIBRARIES (see `InjectedDylibs`).
./VirtualNetwork/build.sh
mkdir -p Sources/Baguette/Resources/VirtualNetwork
cp -f VirtualNetwork/VirtualNetwork.dylib Sources/Baguette/Resources/VirtualNetwork/

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
swift build -c release

# Drop the binary at the workspace root so the Makefile / install scripts
# find it where they always have.
cp -f .build/release/Baguette ./Baguette
echo "Build complete: ./Baguette"
