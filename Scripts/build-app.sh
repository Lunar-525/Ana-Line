#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD_CONFIGURATION=${1:-release}
case "$BUILD_CONFIGURATION" in
    release|debug) ;;
    *) printf 'Expected build configuration: release or debug\n' >&2; exit 2 ;;
esac
if [ "$BUILD_CONFIGURATION" = debug ]; then
    printf 'Debug build: DSP is unoptimized. Use ./build.sh --release for video playback.\n' >&2
fi
if [ "$#" -gt 1 ]; then
    printf 'Usage: sh Scripts/build-app.sh [release|debug]\n' >&2
    exit 2
fi
swift build -c "$BUILD_CONFIGURATION"
BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)
APP="build/AnaLine.app/Contents"
BUILD_ID=$(printf '%X' "$(date +%s)")
BUILD_TIME=$(date '+%Y-%m-%d %H:%M:%S %z')
mkdir -p "$APP/MacOS" "$APP/Resources"
cp "$BIN_DIR/AnaLine" "$APP/MacOS/AnaLine.next"
mv -f "$APP/MacOS/AnaLine.next" "$APP/MacOS/AnaLine"
sed -e "s/__BUILD_ID__/$BUILD_ID/g" -e "s/__BUILD_TIME__/$BUILD_TIME/g" \
    -e "s/__BUILD_CONFIGURATION__/$BUILD_CONFIGURATION/g" Scripts/Info.plist > "$APP/Info.plist"
# The local sample is excluded from version control.
if [ -f Assets/bliss.jpg ]; then
    cp Assets/bliss.jpg "$APP/Resources/bliss.jpg"
fi
cp Design/Icon/AnaLine.icns "$APP/Resources/AnaLine.icns"
cp -R Assets/FilmLuts "$APP/Resources/"
cp -R Assets/LUTLibrary "$APP/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Resources/"
mkdir -p "$APP/Resources/ThirdParty/CHOWTape"
cp ThirdParty/CHOWTape/LICENSE ThirdParty/CHOWTape/NOTICE.md "$APP/Resources/ThirdParty/CHOWTape/"
# SwiftPM places processed localized resources in a companion bundle.
# Embed it in the app so Settings language selection works in the packaged build.
RESOURCE_BUNDLE="$BIN_DIR/AnaLine_AnalogGUI.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    # Flatten the SwiftPM resource bundle into the application bundle so
    # SwiftUI's LocalizedStringKey lookup can find zh-Hans.lproj directly.
    cp -R "$RESOURCE_BUNDLE/Contents/Resources/." "$APP/Resources/"
fi
# Flatten the AnalogCore resource bundle too, so TapeFormulations.json lands in
# Contents/Resources where TapeFormulationLibrary searches for it. Doing this
# here avoids relying on Bundle.module, which traps in a packaged app.
CORE_BUNDLE="$BIN_DIR/AnaLine_AnalogCore.bundle"
if [ -d "$CORE_BUNDLE" ]; then
    cp -R "$CORE_BUNDLE/Contents/Resources/." "$APP/Resources/"
fi
codesign --force --sign - "build/AnaLine.app"
# Replacing bundle contents leaves the outer directory timestamp unchanged.
# Refresh it so Finder and Quick Look can invalidate the previous app preview.
touch "build/AnaLine.app"
echo "Built build/AnaLine.app"
