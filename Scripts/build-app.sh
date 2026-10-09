#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="build/AnaLine.app/Contents"
BUILD_ID=$(printf '%X' "$(date +%s)")
BUILD_TIME=$(date '+%Y-%m-%d %H:%M:%S %z')
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BIN_DIR/AnaLine" "$APP/MacOS/AnaLine.next"
mv -f "$APP/MacOS/AnaLine.next" "$APP/MacOS/AnaLine"
sed -e "s/__BUILD_ID__/$BUILD_ID/g" -e "s/__BUILD_TIME__/$BUILD_TIME/g" Scripts/Info.plist > "$APP/Info.plist"
# The local sample is excluded from version control.
if [ -f Assets/bliss.jpg ]; then
    cp Assets/bliss.jpg "$APP/Resources/bliss.jpg"
fi
cp Design/Icon/AnaLine.icns "$APP/Resources/AnaLine.icns"
cp -R Assets/FilmLuts "$APP/Resources/"
cp -R Assets/LUTLibrary "$APP/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Resources/"
# SwiftPM places processed localized resources in a companion bundle.
# Embed it in the app so Settings language selection works in the packaged build.
RESOURCE_BUNDLE="$BIN_DIR/AnaLine_AnalogGUI.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    # Flatten the SwiftPM resource bundle into the application bundle so
    # SwiftUI's LocalizedStringKey lookup can find zh-Hans.lproj directly.
    cp -R "$RESOURCE_BUNDLE/Contents/Resources/." "$APP/Resources/"
fi
codesign --force --sign - "build/AnaLine.app"
# Replacing bundle contents leaves the outer directory timestamp unchanged.
# Refresh it so Finder and Quick Look can invalidate the previous app preview.
touch "build/AnaLine.app"
echo "Built build/AnaLine.app"
