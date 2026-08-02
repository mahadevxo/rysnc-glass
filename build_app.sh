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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/lib"

cp .build/release/RsyncGlass "$APP/Contents/MacOS/RsyncGlass"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Non-system dylibs a Mach-O links against. Everything under /usr/lib and
# /System ships with macOS, so only the rest has to travel with us.
foreign_dylibs() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -v '^/usr/lib/' | grep -v '^/System/' \
        | grep -v '^@' || true
}

# Copy a Homebrew dylib in next to the binaries and repoint the reference at
# it. Homebrew links with absolute /opt/homebrew paths (no @rpath), so a
# straight `cp` of rsync alone produces a binary that dyld refuses to launch
# on any Mac without Homebrew — the exact machine this bundling exists for.
# Walks dependencies transitively; each dylib can pull in more.
bundle_dylibs_for() {
    local target="$1" dep base
    for dep in $(foreign_dylibs "$target"); do
        base="$(basename "$dep")"
        if [[ ! -f "$APP/Contents/Resources/lib/$base" ]]; then
            if [[ ! -f "$dep" ]]; then
                echo "error: $target needs $dep, which isn't on this machine." >&2
                exit 1
            fi
            cp "$dep" "$APP/Contents/Resources/lib/$base"
            chmod u+w "$APP/Contents/Resources/lib/$base"
            # An install name of its own real path would make anything linking
            # it reach back out to /opt/homebrew again.
            install_name_tool -id "@loader_path/$base" "$APP/Contents/Resources/lib/$base" 2>/dev/null
            echo "  bundled dylib $base"
            bundle_dylibs_for "$APP/Contents/Resources/lib/$base"
        fi
        # bin/ and lib/ are siblings, so this resolves from either location.
        install_name_tool -change "$dep" "@loader_path/../lib/$base" "$target" 2>/dev/null
    done
}

# Bundle rsync/sshpass so the app works without Homebrew. Best-effort on
# whether a binary is available: if this build machine lacks one, skip it and
# let CommandLocator fall back to searching install paths at runtime, same as
# before bundling existed. Not best-effort once we do bundle one — a bundled
# binary that can't launch is worse than none, so dylib failures are fatal.
bundle_binary() {
    local name="$1" src dest
    src="$(command -v "$name" 2>/dev/null || true)"
    if [[ -z "$src" || ! -x "$src" ]]; then
        echo "warning: $name not found on this machine — app will rely on a system install at runtime" >&2
        return
    fi
    # Apple's /usr/bin/rsync is 2.6.9-compatible openrsync. Bundling it would
    # pin every user of this build to it — including users who have a modern
    # rsync installed, since the bundled copy takes precedence at runtime.
    if [[ "$src" == /usr/bin/* || "$src" == /bin/* ]]; then
        echo "warning: skipping $name — $src is the old macOS build, not worth bundling" >&2
        return
    fi
    dest="$APP/Contents/Resources/bin/$name"
    cp "$src" "$dest"
    chmod u+w "$dest"
    echo "Bundled $name from $src"
    bundle_dylibs_for "$dest"
}
bundle_binary rsync
bundle_binary sshpass

echo "Codesigning (ad-hoc)…"
# Finder/Spotlight can tag freshly written files with a com.apple.FinderInfo
# xattr fast enough that codesign then rejects the bundle outright
# ("resource fork ... detritus not allowed"). Clearing first is cheaper than
# racing it.
xattr -cr "$APP" 2>/dev/null || true
# Sign bundled binaries and dylibs individually first: they sit under
# Resources, not one of the standard Frameworks/PlugIns spots --deep walks,
# and install_name_tool invalidates whatever signature they arrived with.
for f in "$APP/Contents/Resources/bin/"* "$APP/Contents/Resources/lib/"*; do
    [[ -f "$f" ]] && codesign --force --sign - "$f"
done
# Finder can re-tag the bundle while the steps above run, so clear again
# immediately before the sign that would trip over it, and retry once.
xattr -cr "$APP" 2>/dev/null || true
if ! codesign --force --deep --sign - "$APP" 2>/dev/null; then
    xattr -cr "$APP" 2>/dev/null || true
    codesign --force --deep --sign - "$APP"
fi

# A bundled rsync that can't launch is the failure this whole section exists
# to prevent, and it's invisible until someone runs the app on a clean Mac.
# Verify here instead, where it's cheap: no dyld fallback, so any surviving
# absolute reference to a missing library fails.
for f in "$APP/Contents/Resources/bin/"*; do
    [[ -f "$f" ]] || continue
    if ! DYLD_FALLBACK_LIBRARY_PATH="" "$f" --version >/dev/null 2>&1 \
        && ! DYLD_FALLBACK_LIBRARY_PATH="" "$f" -V >/dev/null 2>&1; then
        echo "error: bundled $(basename "$f") doesn't run — check its linkage:" >&2
        otool -L "$f" >&2
        exit 1
    fi
    echo "Verified bundled $(basename "$f") launches"
done

echo "Built $APP"
