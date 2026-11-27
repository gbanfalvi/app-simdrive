#!/bin/sh
# Builds the probe app into .build/probe, and installs it on the simulator when given its UDID.
# With --device <hardware-udid> <team-id>, builds it into .build/probe-device for that physical device instead, signed
# with the team's development profile, which xcodebuild creates or updates through the Mac's Xcode account.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" = "--device" ]; then
    xcodebuild -project "$here/Probe/AXProbe.xcodeproj" -scheme AXProbe -configuration Release -destination "id=$2" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM="$3" \
        SYMROOT="$here/../.build/probe-device" build -quiet
    echo "$here/../.build/probe-device/Release-iphoneos/AXProbe.app"
    exit 0
fi

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
