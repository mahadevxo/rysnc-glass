# RsyncGlass

A native macOS app for `rsync` transfers — local↔local, local↔SSH remote, or remote↔remote (relayed through a local staging folder, since `rsync` itself can't go host-to-host directly).

## Features

- Source and target can each be a local folder, a remote SSH server (host/port/username, key or password auth), or cloud storage from your rclone config (Google Drive, S3, …)
- Add, test and delete cloud remotes inside the app: pick any of rclone's ~70 providers and fill in a form generated from rclone's own description of it. Providers that need a sign-in (Google Drive, Dropbox, OneDrive…) open your browser, and any follow-up questions rclone asks are shown in the app. Passwords are stored obscured in your rclone config, the way rclone itself stores them
- Saved server profiles — save a connection once, pick it from a menu next time. Passwords go in Keychain, never in a plaintext settings file
- Browse button for remote paths — navigates the remote filesystem live over SSH, no need to type paths blind
- Real parallel transfers — indexes the source (size *and* file count per item) and breaks it into chunks, opening up any folder too big to deal out evenly (including flat folders of thousands of files), then runs N `rsync` processes that each take the next chunk as soon as they're free. Chunks start large and shrink as the queue drains, so streams finish close together even when a folder turns out slower than its size suggested, and no stream sits idle while another grinds on
- Resumes interrupted transfers (`--partial`) instead of starting over
- Live progress that means something: total % weighted by files as well as bytes (so a long tail of small files doesn't sit at 99%), current speed, time elapsed, and estimated time remaining
- Each window is its own independent transfer — open a new window (⌘N) to run another one alongside
- Remote-to-remote transfers go server-to-server directly when the source can reach the target: the source runs rsync straight to the target, so the data never passes through this Mac. When it can't, the data streams through this Mac with rclone (nothing staged on disk), or relays through local staging with rsync, whichever you choose
- Picks the right engine per transfer: rsync for everything it's best at (delta transfer, permissions, resume), rclone for cloud storage, for streaming between servers that can't see each other, and for downloading one large file as parallel pieces
- Network-aware: compression is turned off automatically for servers on the local network, where it costs more CPU time than it saves
- Standard `rsync` options: archive mode, delete-extraneous, dry run, bandwidth limit, exclude patterns, extra flags
- Swap button to flip source/target, and confirmation prompts before a transfer that would delete files or where source and target point at the same place
- Warns before quitting mid-transfer instead of silently orphaning the running `rsync`/`ssh` processes

## Requirements

**To run the built app:** macOS 26 (Tahoe) or later.

**To build it yourself:**
- macOS 26 or later
- Xcode 26 or later — the **full app**, not just the Command Line Tools (`xcode-select --install` alone won't have the macOS 26 SDK this needs)

The prebuilt app bundles its own copies of `rsync`, `sshpass` and `rclone` (Apple Silicon only — see Notes below), so none of them needs to be installed separately. For cloud storage, add remotes from the app (Cloud endpoint → Manage…); they're stored in your normal rclone config, so remotes made with `rclone config` show up too. If you build it yourself and Homebrew's `rsync`/`sshpass` are on `PATH` at build time, `build_app.sh` bundles those; otherwise the app falls back to searching common install locations (Homebrew, `/usr/bin`, etc.) at runtime, same as before bundling existed.

**Optional, if not bundled:**
- [Homebrew](https://brew.sh) `rsync` (`brew install rsync`) — macOS ships an ancient rsync (2.6.9) for licensing reasons; the app detects and works around it either way, but a modern one enables nicer progress reporting
- `sshpass`, only if you want password-based SSH auth instead of keys: `brew install hudochenkov/sshpass/sshpass`
- `rclone` (`brew install rclone`) for development builds run with `swift run`, which don't bundle it — needed for cloud storage, rclone streaming between servers, and parallel-piece downloads

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

### End-to-end tests against real SSH servers

The SSH-dependent paths (direct server-to-server, rclone streaming, password login through rclone, parallel-piece downloads) have end-to-end tests in `SSHEndToEndTests.swift`. They're skipped unless pointed at two SSH servers. To run them with Docker, build a small image with `sshd` and `rsync` for a user `tester` (key and password login, a throwaway key in its `authorized_keys`), put some test data under `/data/src` and a file of at least 1 GiB at `/data/big.iso` on the source, and publish the source on port 2221 and the target on 2222, both on this Mac's LAN IP so the source container can reach the target. Also publish the target on `127.0.0.1:2232`, a port only this Mac can reach, which exercises the fallback to rclone. Then:

```sh
RG_E2E_HOST=$(ipconfig getifaddr en0) RG_E2E_KEY=/path/to/throwaway_key RG_E2E_PASSWORD=... ./run_tests.sh
```

These runs add the test servers' host keys to `~/.ssh/known_hosts` (the app accepts new host keys on first use); remove them afterwards with `ssh-keygen -R "[<ip>]:2221"` and so on.

## Notes

- rsync can't transfer between two remote hosts on its own, so for remote-to-remote RsyncGlass first tries going direct: it runs rsync on the source server, sending to the target. The source logs in to the target with your key via a temporary ssh-agent that holds only that key and is forwarded for the length of the transfer, so the key itself never leaves this Mac. This needs rsync on both servers, the source able to reach the target at the address you gave, and key auth for the target. If any of that is missing, the log says which, and the data goes through this Mac instead: streamed by rclone (nothing on disk, but changed files are sent whole and permissions and ownership aren't kept), or relayed by rsync through a local staging folder one chunk at a time, deleting each chunk once it's confirmed on the target so the transfer isn't bounded by this Mac's free disk space. The relay's "Overlap upload with next download" option trades some of that disk headroom for speed. A small manifest in the staging folder tracks finished items, so resuming an interrupted relay skips them. Dry run through the relay only previews the download leg.
- Splitting inside a directory kicks in when an item costs more than an eighth of one stream's share, for up to four levels, however many entries a folder holds (names per chunk are capped instead, to stay under the command-line length limit). It doesn't apply with a single stream, so a remote-to-remote relay of one enormous folder on one stream still stages that whole folder.
- "Automatic" network tuning treats private addresses (192.168.x, 10.x, 172.16–31.x, `.local` names, and names that resolve to those) as local network and turns compression off for them. 100.64.x (Tailscale, CGNAT) counts as internet, since those peers can be anywhere. Delta transfer stays on either way, because it's what lets `--partial` resume a half-copied file.
- Transfers to or from a `127.0.0.1`/`localhost` server (typically an SSH tunnel) through rclone skip host-key verification, matching ssh itself, which never records loopback host keys.
- The app is ad-hoc signed only, not notarized. That's fine for building and running on your own Mac, but if you hand the built `.app` file to someone else directly (rather than having them build it themselves), Gatekeeper will likely flag it — they'd need to right-click → Open, or clear the quarantine attribute (`xattr -cr RsyncGlass.app`).
- If `./build_app.sh` prints a `resource fork, Finder information, or similar detritus not allowed` warning during codesigning, that's the same Finder-tagging quirk mentioned above — it's non-fatal for `build_app.sh` (ad-hoc signing an app bundle tolerates it; only the stricter test-bundle signing step fails outright), and the built app still runs fine.
- `build_app.sh` bundles `rsync`/`sshpass` from whatever's on the build machine's `PATH`, skipping Apple's `/usr/bin/rsync` (that's the 2.6.9-compatible build — bundling it would pin every user of the app to it). Homebrew links `rsync` against dylibs under `/opt/homebrew`, so those get copied into `Contents/Resources/lib` and the references rewritten to `@loader_path` — otherwise the bundled binary wouldn't launch on the Homebrew-less Macs this bundling exists for. The build verifies each bundled binary actually runs before finishing.
- `build_app.sh` also bundles rclone: the official release, pinned by version and SHA-256 in the script, downloaded once and cached in `~/Library/Caches/RsyncGlass-build`. rclone is MIT-licensed ([rclone.org](https://rclone.org/)).
- Bundled binaries are the upstream builds with library paths relocated and an ad-hoc signature applied; the code is otherwise unmodified. rsync and sshpass are GPL — rsync GPLv3 ([rsync.samba.org](https://rsync.samba.org/)), sshpass GPLv2 ([sourceforge.net/projects/sshpass](https://sourceforge.net/projects/sshpass/)) — not RsyncGlass's own license, and redistributing them carries the GPL's corresponding-source obligation, which a link alone doesn't discharge. If you redistribute your own build, make matching source available (Homebrew's formulae identify the exact upstream versions).
- Releases built on Apple Silicon bundle arm64 binaries only. `CommandLocator` launch-probes a candidate before committing to it, so on an Intel Mac the arm64 bundled copy is rejected (it can't exec) and the app falls back to a system-installed `rsync`/`sshpass` — the same search it used before bundling existed.
