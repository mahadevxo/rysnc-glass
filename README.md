# RsyncGlass

A native macOS app for `rsync` transfers — local↔local, local↔SSH remote, or remote↔remote (relayed through a local staging folder, since `rsync` itself can't go host-to-host directly).

## Features

- Source and target can each be a local folder or a remote SSH server (host/port/username, key or password auth)
- Saved server profiles — save a connection once, pick it from a menu next time. Passwords go in Keychain, never in a plaintext settings file
- Browse button for remote paths — navigates the remote filesystem live over SSH, no need to type paths blind
- Real parallel transfers — splits the source into N size-balanced groups and runs N `rsync` processes concurrently over separate connections
- Resumes interrupted transfers (`--partial`) instead of starting over
- Standard `rsync` options: compression, archive mode, delete-extraneous, dry run, bandwidth limit, exclude patterns, extra flags

## Requirements

**To run the built app:** macOS 26 (Tahoe) or later.

**To build it yourself:**
- macOS 26 or later
- Xcode 26 or later — the **full app**, not just the Command Line Tools (`xcode-select --install` alone won't have the macOS 26 SDK this needs)

**Optional, for the smoothest experience:**
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

## Notes

- rsync can't transfer directly between two remote hosts. If both source and target are remote, RsyncGlass relays through a local staging folder automatically (download → stage → upload) — this shows up as "Stage 1 of 2" / "Stage 2 of 2" in the transfer log.
- The app is ad-hoc signed only, not notarized. That's fine for building and running on your own Mac, but if you hand the built `.app` file to someone else directly (rather than having them build it themselves), Gatekeeper will likely flag it — they'd need to right-click → Open, or clear the quarantine attribute (`xattr -cr RsyncGlass.app`).
