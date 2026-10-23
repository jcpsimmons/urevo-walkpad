#!/usr/bin/env bash
# Build Walkpad.app, install it to ~/Applications and put the `walkpad` CLI on PATH.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Walkpad.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp app/Info.plist "$APP/Contents/Info.plist"
swiftc -parse-as-library -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
  app/main.swift -o "$APP/Contents/MacOS/Walkpad"
codesign --force --sign - "$APP"
mkdir -p ~/Applications ~/.local/bin
rm -rf ~/Applications/Walkpad.app
cp -R "$APP" ~/Applications/
ln -sf "$PWD/walkpad" ~/.local/bin/walkpad
echo "installed ~/Applications/Walkpad.app and ~/.local/bin/walkpad"
