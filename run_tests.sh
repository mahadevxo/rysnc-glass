#!/bin/bash
# Builds and runs the test suite.
#
# `swift test` codesigns the .xctest bundle as part of the same build step
# that creates it. On this Mac, something (Finder/Launch Services recognizing
# the .xctest bundle extension) tags the freshly-created bundle directory with
# a com.apple.FinderInfo xattr almost immediately, and this toolchain's
# codesign rejects that outright ("resource fork ... detritus not allowed").
# It happens too close to bundle-creation time to just strip-then-build, so a
# background watcher strips it continuously for the life of the build.
set -euo pipefail

cd "$(dirname "$0")"

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

mkdir -p .build
touch .build/.metadata_never_index

watch_and_strip() {
    local target=".build/out/Products/Debug/RsyncGlassTests.xctest"
    while true; do
        [[ -e "$target" ]] && xattr -c "$target" 2>/dev/null
        sleep 0.02
    done
}

watch_and_strip &
WATCHER_PID=$!
trap 'kill "$WATCHER_PID" 2>/dev/null || true' EXIT

echo "Building tests…"
swift build --build-tests

kill "$WATCHER_PID" 2>/dev/null || true
trap - EXIT
xattr -c .build/out/Products/Debug/RsyncGlassTests.xctest 2>/dev/null || true

echo "Running tests…"
swift test --skip-build
