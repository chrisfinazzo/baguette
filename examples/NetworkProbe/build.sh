#!/bin/bash
# Build and install NetworkProbe.app onto a booted simulator.
#
#   ./build.sh <UDID>
#
# No Xcode project: one ObjC file compiled against the iphonesimulator SDK
# and packaged into a .app by hand, the same way VirtualNetwork.dylib is
# built. Ad-hoc signed, which is what the simulator wants for an app bundle
# (unlike the injected dylibs, which must keep their linker signature).
set -e
cd "$(dirname "$0")"

UDID="${1:?usage: ./build.sh <UDID>}"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
APP=build/NetworkProbe.app
BUNDLE_ID=com.baguette.networkprobe

rm -rf build
mkdir -p "$APP"

xcrun clang \
    -arch arm64 \
    -isysroot "$SDK" \
    -target arm64-apple-ios17.0-simulator \
    -framework UIKit \
    -framework WebKit \
    -framework Foundation \
    -fobjc-arc \
    -Wall \
    -o "$APP/NetworkProbe" \
    Sources/main.m

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>NetworkProbe</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>NetworkProbe</string>
  <key>CFBundleDisplayName</key><string>Network Probe</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

xcrun simctl install "$UDID" "$APP"
echo "Installed $BUNDLE_ID on $UDID"
echo "Launch with: xcrun simctl launch --terminate-running-process $UDID $BUNDLE_ID"
