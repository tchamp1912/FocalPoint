#!/bin/sh
# Build FocalPoint.app — the FocalPoint menu-bar app (macOS 14+, Apple Silicon).
# swiftc only, no Xcode project. MIT License.
set -eu
cd "$(dirname "$0")"

APP="FocalPoint.app"
MACOS_DIR="$APP/Contents/MacOS"
BIN="$MACOS_DIR/FocalPoint"
RESOURCES_DIR="$APP/Contents/Resources"

# Liquid Glass (glassEffect / GlassEffectContainer / .buttonStyle(.glass)) is
# macOS 26 API and simply absent from older SDKs, so it has to be gated at
# compile time as well as at runtime. Define FOCALPOINT_LIQUID_GLASS only when
# the active SDK can see those symbols; Sources/Glass.swift keeps the current
# materials otherwise. The deployment target stays 14.0 either way, so a
# binary built on the new SDK still runs (and falls back) on macOS 14/15.
SDK_VERSION="$(xcrun --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
GLASS_FLAGS=""
if [ "$SDK_MAJOR" -ge 26 ]; then
    GLASS_FLAGS="-D FOCALPOINT_LIQUID_GLASS"
    echo "==> SDK $SDK_VERSION: Liquid Glass enabled"
else
    echo "==> SDK $SDK_VERSION: Liquid Glass needs the macOS 26 SDK — building with the standard materials"
fi

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Assets"

ICONSET_DIR="$(mktemp -d /tmp/focalpoint-iconset.XXXXXX)"
trap 'rm -rf "$ICONSET_DIR"' EXIT
swiftc -O -framework AppKit -o "$ICONSET_DIR/make-appicon" tools/make-appicon.swift
"$ICONSET_DIR/make-appicon" "$(pwd)/Assets/AppIcon.icon" "$ICONSET_DIR/AppIcon.iconset"
iconutil --convert icns --output "$RESOURCES_DIR/AppIcon.icns" "$ICONSET_DIR/AppIcon.iconset"

# shellcheck disable=SC2086  # GLASS_FLAGS is intentionally word-split (empty = no flag)
swiftc -O \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework Carbon \
    $GLASS_FLAGS \
    -o "$BIN" \
    Sources/*.swift

echo "==> assembling bundle"
cp Info.plist "$APP/Contents/Info.plist"
cp -R Assets/AppIcon.icon "$APP/Contents/Resources/AppIcon.icon"
cp Assets/focalpoint-mark.svg "$RESOURCES_DIR/Assets/focalpoint-mark.svg"
cp Assets/focalpoint-mark-menubar.svg "$RESOURCES_DIR/Assets/focalpoint-mark-menubar.svg"
cp Assets/focalpoint-mark-menu.svg "$RESOURCES_DIR/Assets/focalpoint-mark-menu.svg"
cp Assets/focalpoint-mark-widget.svg "$RESOURCES_DIR/Assets/focalpoint-mark-widget.svg"
cp Assets/focalpoint-disconnected.svg "$RESOURCES_DIR/Assets/focalpoint-disconnected.svg"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep -s - "$APP"

echo "built: $(pwd)/$APP"
