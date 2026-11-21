#!/bin/sh
# Builds build/Downmix51.app (menu-bar router) with the 6-channel "Downmix51" driver embedded inside it.
# Needs only the Xcode Command Line Tools (clang + swiftc); full Xcode is not required.
set -eu
cd "$(dirname "$0")"

BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Driver (6 channels / 5.1)"
DRV="$BUILD/Downmix51.driver"
mkdir -p "$DRV/Contents/MacOS" "$DRV/Contents/Resources"
clang -bundle -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -Wno-format-extra-args -Wno-unused-but-set-variable \
    -DkNumber_Of_Channels=6 \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate \
    driver/BlackHole.c -o "$DRV/Contents/MacOS/Downmix51"
cp driver/Info.plist "$DRV/Contents/Info.plist"
cp driver/BlackHole.icns "$DRV/Contents/Resources/"
codesign --force --sign - "$DRV"

echo "==> App"
APP="$BUILD/Downmix51.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# App is built for this Mac's architecture (override: APP_ARCH=x86_64 ./build.sh).
APP_ARCH="${APP_ARCH:-$(uname -m)}"
swiftc -O -swift-version 5 -parse-as-library \
    -target "$APP_ARCH-apple-macos13.0" \
    app/Sources/*.swift -o "$APP/Contents/MacOS/Downmix51"
cp app/Info.plist "$APP/Contents/Info.plist"
cp -R "$DRV" "$APP/Contents/Resources/"     # the app installs this itself on first launch
codesign --force --sign - "$APP"

echo "==> Done: $DRV and $APP"
