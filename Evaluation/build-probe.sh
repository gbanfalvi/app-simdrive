#!/bin/sh
# Builds the probe app into .build/probe, and installs it on the simulator when given its UDID.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app="$here/../.build/probe/AXProbe.app"
minimum=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$here/Probe/Info.plist")

mkdir -p "$app"
cp "$here/Probe/Info.plist" "$app/Info.plist"
xcrun --sdk iphonesimulator swiftc -O -target "arm64-apple-ios$minimum-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -module-name AXProbe "$here/Probe/main.swift" -o "$app/AXProbe"
codesign --sign - --force "$app" >/dev/null 2>&1

if [ $# -gt 0 ]; then
    xcrun simctl install "$1" "$app"
fi
echo "$app"
