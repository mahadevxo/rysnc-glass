#!/bin/bash
# Builds RsyncGlass in release mode and packages it as RsyncGlass.app.
set -euo pipefail

cd "$(dirname "$0")"

# Needs a full Xcode 26+ install (not just Command Line Tools) for the macOS 26
# SDK and Package.swift's swift-tools-version 6.2. Prefer whatever
# `xcode-select` already points at; only search /Applications if that's just
# the Command Line Tools.
find_developer_dir() {
    local selected
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$selected" == *"/Xcode"*".app/Contents/Developer" ]]; then
        echo "$selected"
        return
    fi

    local candidate
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            echo "$candidate/Contents/Developer"
            return
        fi
    done
}

DEVELOPER_DIR="$(find_developer_dir)"
if [[ -z "$DEVELOPER_DIR" ]]; then
    echo "error: couldn't find a full Xcode install (Command Line Tools alone aren't enough)." >&2
    echo "Install Xcode 26 or later from the App Store, open it once to accept the license, then run this script again." >&2
    exit 1
fi
export DEVELOPER_DIR
echo "Using Xcode at $DEVELOPER_DIR"

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
