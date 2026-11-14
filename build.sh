#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=Klappkordeon.app
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
swiftc -O -swift-version 5 -parse-as-library main.swift -o "$APP/Contents/MacOS/Klappkordeon"
cp Info.plist "$APP/Contents/"
swiftc -swift-version 5 make_icon.swift -o build/make_icon
build/make_icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Fertig: $(pwd)/$APP"
