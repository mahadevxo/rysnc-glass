# RsyncGlass

A native macOS app for `rsync` transfers — local↔local, local↔SSH remote, or remote↔remote (relayed through a local staging folder, since `rsync` itself can't go host-to-host directly).

## Features

- Source and target can each be a local folder or a remote SSH server (host/port/username, key or password auth)
- Saved server profiles — save a connection once, pick it from a menu next time. Passwords go in Keychain, never in a plaintext settings file
- Browse button for remote paths — navigates the remote filesystem live over SSH, no need to type paths blind
- Real parallel transfers — splits the source into N size-balanced groups and runs N `rsync` processes concurrently over separate connections
- Resumes interrupted transfers (`--partial`) instead of starting over
- Remote-to-remote transfers relay item by item, deleting each item from local staging as soon as it's confirmed on the target — so a transfer can move more data than fits on this Mac's free disk at once. Optionally overlaps each item's upload with the next item's download for speed, at the cost of roughly double the peak local disk per stream
- Standard `rsync` options: compression, archive mode, delete-extraneous, dry run, bandwidth limit, exclude patterns, extra flags
- Swap button to flip source/target, and confirmation prompts before a transfer that would delete files or where source and target point at the same place
- Warns before quitting mid-transfer instead of silently orphaning the running `rsync`/`ssh` processes

## Requirements

**To run the built app:** macOS 26 (Tahoe) or later.

**To build it yourself:**
- macOS 26 or later
- Xcode 26 or later — the **full app**, not just the Command Line Tools (`xcode-select --install` alone won't have the macOS 26 SDK this needs)

The prebuilt app bundles its own copies of `rsync` and `sshpass` (Apple Silicon only — see Notes below), so neither needs to be installed separately. If you build it yourself and Homebrew's `rsync`/`sshpass` are on `PATH` at build time, `build_app.sh` bundles those; otherwise the app falls back to searching common install locations (Homebrew, `/usr/bin`, etc.) at runtime, same as before bundling existed.

**Optional, if not bundled:**
- [Homebrew](https://brew.sh) `rsync` (`brew install rsync`) — macOS ships an ancient rsync (2.6.9) for licensing reasons; the app detects and works around it either way, but a modern one enables nicer progress reporting
- `sshpass`, only if you want password-based SSH auth instead of keys: `brew install hudochenkov/sshpass/sshpass`

## Building

```sh
git clone <this repo>
cd RsyncGlass
./build_app.sh
```

This produces `RsyncGlass.app` in the project folder, ad-hoc signed so it runs directly on your own Mac. Double-click it, or drag it to `/Applications`.

If you'd rather iterate without producing a full `.app` bundle:

```sh
swift run
```

(You may need `export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"` first if `xcode-select` currently points at Command Line Tools rather than full Xcode.)

## Testing

```sh
./run_tests.sh
```

Runs the full test suite (`Tests/RsyncGlassTests`), including integration tests that spin up real local `rsync` processes to verify parallel-stream splitting, resume-after-cancel, and the remote-to-remote relay routing — not just pure-logic unit tests.

This is a wrapper around `swift test` rather than calling it directly, because on some Macs Finder/Spotlight tags a freshly-built `.xctest` bundle with a `com.apple.FinderInfo` xattr fast enough to make `codesign` reject it mid-build ("resource fork ... detritus not allowed"). If you ever see that error running `swift test` yourself, use `./run_tests.sh` instead.

## Notes

- rsync can't transfer directly between two remote hosts. If both source and target are remote, RsyncGlass relays through a local staging folder automatically, one top-level item at a time — each item is downloaded, uploaded, and then deleted from staging before moving to the next, so the transfer isn't bounded by this Mac's free disk space. The "Overlap upload with next download" option in the Options panel trades some of that disk headroom for speed by starting the next item's download while the current one is still uploading. A small manifest in the staging folder tracks which items already finished, so resuming an interrupted relay skips them instead of re-downloading. Dry run only ever previews the download leg — nothing is actually uploaded or deleted from staging.
- The app is ad-hoc signed only, not notarized. That's fine for building and running on your own Mac, but if you hand the built `.app` file to someone else directly (rather than having them build it themselves), Gatekeeper will likely flag it — they'd need to right-click → Open, or clear the quarantine attribute (`xattr -cr RsyncGlass.app`).
- If `./build_app.sh` prints a `resource fork, Finder information, or similar detritus not allowed` warning during codesigning, that's the same Finder-tagging quirk mentioned above — it's non-fatal for `build_app.sh` (ad-hoc signing an app bundle tolerates it; only the stricter test-bundle signing step fails outright), and the built app still runs fine.
- Bundled `rsync`/`sshpass` are unmodified upstream binaries, each under the GPL (rsync: GPLv3, [rsync.samba.org](https://rsync.samba.org/); sshpass: GPLv2, [sourceforge.net/projects/sshpass](https://sourceforge.net/projects/sshpass/)) — not RsyncGlass's own license. They're copied in as-is by `build_app.sh` from whatever's on the build machine's `PATH` at build time (currently Homebrew's arm64 builds), so a release built on Apple Silicon only bundles arm64 binaries; on an Intel Mac without matching binaries on `PATH`, `CommandLocator` falls back to a system-installed `rsync`/`sshpass` at runtime instead.
