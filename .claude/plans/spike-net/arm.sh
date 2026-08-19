#!/bin/bash
# Rebuild the spike and arm it, always under a fresh sha-keyed path — iOS 26's
# simulator dyld page-hash cache rejects a replaced dylib at the same path.
set -e
cd "$(dirname "$0")"
UDID=FDF48F28-12D6-4772-84D5-489516D81A37

./build.sh > /dev/null
SHA=$(shasum -a 256 SpikeNet.dylib | cut -c1-12)
DEST="$HOME/Library/Application Support/Baguette/builds/spike-$SHA"
mkdir -p "$DEST"
cp -f SpikeNet.dylib "$DEST/SpikeNet.dylib"
chmod 755 "$DEST/SpikeNet.dylib"
xcrun simctl spawn "$UDID" launchctl setenv DYLD_INSERT_LIBRARIES "$DEST/SpikeNet.dylib"
echo "armed $DEST/SpikeNet.dylib"
