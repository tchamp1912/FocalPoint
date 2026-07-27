#!/bin/sh
# Build the FocalPoint keyboard-backlight helper (macOS only, no dependencies).
# MIT License - see adapters/README.md
set -eu
cd "$(dirname "$0")"
swiftc -O -o focalpoint-backlight backlight.swift
echo "built: $(pwd)/focalpoint-backlight"
