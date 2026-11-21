#!/bin/sh
# Builds build/Downmix51Test.app: the e2e tool wrapped in a bundle so it can get Microphone permission.
set -eu
cd "$(dirname "$0")/.."
T=build/Downmix51Test.app
rm -rf "$T"; mkdir -p "$T/Contents/MacOS"
swiftc -O tests/e2e.swift -o "$T/Contents/MacOS/e2e"
cat > "$T/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>e2e</string>
<key>CFBundleIdentifier</key><string>local.downmix51.e2etest</string>
<key>CFBundleName</key><string>Downmix51 Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>The Downmix51 test reads a loopback device to measure the stereo downmix.</string>
</dict></plist>
PL
codesign --force --sign - "$T"
echo "built $T"
