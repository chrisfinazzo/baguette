#!/bin/bash
set -e
cd "$(dirname "$0")"

# The iOS-Simulator side of the camera feature — see Injected/VirtualCamera/.
# Cross-compiled against the iphonesimulator SDK (fat: arm64 + x86_64),
# linker-signed adhoc. Staged into Sources/Baguette/Resources/VirtualCamera/
# so SPM bundles it as a `.copy` resource.
./Injected/VirtualCamera/build.sh
mkdir -p Sources/Baguette/Resources/VirtualCamera
cp -f Injected/VirtualCamera/VirtualCamera.dylib Sources/Baguette/Resources/VirtualCamera/

# The iOS-Simulator side of the motion feature — see Injected/VirtualMotion/. Same
# shape as the camera dylib above: cross-compiled fat, linker-signed adhoc,
# staged for SPM to bundle. Both are armed through one shared
# DYLD_INSERT_LIBRARIES (see `InjectedDylibs`).
./Injected/VirtualMotion/build.sh
mkdir -p Sources/Baguette/Resources/VirtualMotion
cp -f Injected/VirtualMotion/VirtualMotion.dylib Sources/Baguette/Resources/VirtualMotion/

# The iOS-Simulator side of network conditioning — see Injected/VirtualNetwork/.
# Third dylib, same shape as the two above; all three are armed through one
# shared DYLD_INSERT_LIBRARIES (see `InjectedDylibs`).
./Injected/VirtualNetwork/build.sh
mkdir -p Sources/Baguette/Resources/VirtualNetwork
cp -f Injected/VirtualNetwork/VirtualNetwork.dylib Sources/Baguette/Resources/VirtualNetwork/

# Pure-SPM build. Private frameworks resolve through the rpath flags +
# linkedFramework declarations in Package.swift.
swift build -c release

# Drop the binary at the workspace root so the Makefile / install scripts
# find it where they always have.
#
# Remove first rather than `cp -f`. macOS caches a binary's code signature
# against its inode, and overwriting in place leaves the kernel validating
# the new bytes against the old cached signature — the copy then dies on
# launch with SIGKILL and no diagnostic. A fresh inode gets evaluated
# honestly.
rm -f ./Baguette
cp .build/release/Baguette ./Baguette
echo "Build complete: ./Baguette"
