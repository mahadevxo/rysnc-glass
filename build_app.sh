#!/bin/bash
# Builds RsyncGlass in release mode and packages it as RsyncGlass.app.
set -euo pipefail

cd "$(dirname "$0")"

export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

echo "Building release binary…"
swift build -c release

APP="RsyncGlass.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/RsyncGlass "$APP/Contents/MacOS/RsyncGlass"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "Codesigning (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
