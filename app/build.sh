#!/bin/sh
# Build FocalPoint.app — the FocalPoint menu-bar app (macOS 14+, Apple Silicon).
# swiftc only, no Xcode project. MIT License.
set -eu
cd "$(dirname "$0")"

APP="FocalPoint.app"
MACOS_DIR="$APP/Contents/MacOS"
BIN="$MACOS_DIR/FocalPoint"

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
mkdir -p "$MACOS_DIR"

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
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --deep -s - "$APP"

echo "built: $(pwd)/$APP"
