# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

blussh monitors host connectivity. It ships as two native versions: a macOS menu bar app built with SwiftUI (`macos/`) and an Omarchy shell bar widget (`omarchy/`, see "Omarchy port" below). The sections below describe the macOS app unless noted. It discovers hosts from SSH config files, Tailscale, and ZeroTier, shows live status in a popover, and notifies when hosts go down or come back up.

## Development Commands

macOS commands run from `macos/` (the Xcode project lives there).

### Building
```bash
# Debug build
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Debug

# Release build
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Release

# Clean build folder
xcodebuild -project blussh.xcodeproj -scheme blussh clean

# Run the app (after building)
open build/Debug/blussh.app   # from macos/
```

### Testing
```bash
# Run unit tests (if they exist)
xcodebuild test -project blussh.xcodeproj -scheme blussh
```

## Architecture Overview

Design spec: `docs/superpowers/specs/2026-09-02-vpn-discovery-design.md`

### Core Architecture Pattern
MVVM with Combine/async-await. Hosts come from pluggable sources; a central
engine monitors them:

1. **AppDelegate** (`macos/blussh/AppDelegate.swift`): Bridges SwiftUI with AppKit, manages the NSStatusItem (hostname + colored status dot).

2. **MonitoringEngine** (`macos/blussh/MonitoringEngine.swift`): ObservableObject running the cycle: discover from enabled sources concurrently → merge ssh-config entries into matching VPN hosts → auto-detect SSH servers (one-time port-22 probe, persisted) → concurrent TCP checks → debounce (2 consecutive readings to confirm a state flip) → notify → publish.

3. **Host sources** (`HostSource` protocol returning `DiscoveryResult`):
   - `SSHConfigSource`: parses ssh config files (direct read, symlinks resolved for GNU Stow, wildcard Host patterns skipped; a multi-name `Host a a.example` line yields one host named after the first name, the rest kept as aliases)
   - `TailscaleSource`: runs `tailscale status --json` (binary auto-detected, override via `tailscaleBinaryPath` default). Hosts get their MagicDNS name (`magicDNS`, DNSName within `MagicDNSSuffix`); `Self` comes back as `DiscoveryResult.selfHost` (published as `engine.selfHost`, never monitored, only offered T3 pairing)
   - `ZeroTierSource`: local API (`localhost:9993` + authtoken.secret) for joined networks, Central API for named members

4. **T3 Code and monitor actions** (spec: "Host actions" in `docs/monitoring-spec.md`, mirrors `omarchy/blussh.py`): `T3.swift` holds the Foundation-only logic (T3 page check and probe, `t3 pair` script, pairing URL extraction/rewrite, redaction, `t3 environment link`, monitor command, `runProcess`); `HostActions.swift` (@MainActor) runs them from the UI: copy the pairing link (concealed pasteboard type), QR window (`QRCode`, CoreImage), link to T3 here, open the monitor in Terminal. The engine probes each Tailscale host (and Self) once and persists the verdict in `hostIsT3/v2`. **Token hygiene**: never print/log/persist `t3 pair` output or put the token in a notification; build errors from `T3.redact`ed output.

5. **UI Layer**: `StatusMenuView` (popover; hosts grouped by source with online counts, tap-to-copy ssh command, T3 button on T3 hosts and in the header for this Mac, context menu with T3 pairing/QR/link, monitor, SSH-monitoring and T3 toggles), `SettingsView`, `NotificationManager` (UNUserNotificationCenter down/up notifications, plus `notifyAction` for action results).

### Key Technical Decisions

1. **Not sandboxed** (removed 2026-09): required to exec the tailscale CLI and read ZeroTier's authtoken. Only remaining entitlement is `network.client`.
2. **Liveness is two signals**: `netOnline` (what the VPN control plane reports) and `sshOnline` (TCP:22 check, 5 s timeout). `MonitoredHost.isOnline` combines them.
3. **Stable host IDs** (`ssh:<host>`, `ts:<name>`, `zt:<nwid>:<nodeId>`) key persisted per-host state in UserDefaults: `hostEnabled/v2`, `hostIsSSH/v2`, `hostIsT3/v2`, `hostConfirmedState/v2`.
4. **Cross-source merge**: ssh-config entries whose HostName matches a VPN host's IP/DNS alias merge into it, contributing user/port/alias so the copied command stays `ssh user@alias`.
5. **ZeroTier Central token** lives in Keychain (`KeychainHelper`, service `cloud.blusa.blussh`, account `zerotier-central-token`).

### Testing without a test target
`MonitoringEngine.merge` and `applyDebounce` are internal (not private) so they
can be smoke-tested (likewise everything in `T3`, `TailscaleSource.parse` and
`QRCode`; `T3.mintPairingURL`/`T3.link` take a fake `run` closure) by compiling the sources with
`swiftc -parse-as-library macos/blussh/*.swift <harness>.swift` plus a small `@main`
async harness (UI files excluded).

### Omarchy port (`omarchy/`)
Omarchy 4 shell (Quickshell) bar-widget plugin, id `blusa.blussh`. `blussh.py`
is a stdlib-only Python port of MonitoringEngine (state in
`~/.local/state/blussh/state.json`); `Service.qml` runs `blussh.py check` on a
timer and `Panel.qml` renders it using Omarchy's `qs.Ui` components, modeled on
`/usr/share/omarchy/shell/plugins/panels/tailscale/`. Keep behavior changes in
sync between the Swift engine and `blussh.py`.

Same actions as the macOS app (spec: "Host actions"):
**T3 pairing** — Tailscale hosts (and `Self`) whose Serve URL serves T3 Code
get `isT3` (one-time probe, persisted like `isSSH`, override `blussh set <id>
t3`); `blussh t3-pair` runs `t3 pair` over ssh and copies only the Pairing
URL with `wl-copy --sensitive`. Never print, log or persist the pairing token.
**Monitor** — `monitorCommand` per SSH host: `ssh -t … btop|htop|top`. Tests:
`python3 omarchy/test_blussh.py`. Dev install: `omarchy/install.sh --link`,
then `omarchy restart shell` after QML edits (symlinked plugins don't
hot-reload).

## Common Development Tasks

### Adding a new host source
Implement `HostSource`, append it in `MonitoringEngine.runCycle()`, add an
enable toggle in SettingsView (defaults key `<name>SourceEnabled`).

### Changing Connection Test Logic
`MonitoringEngine.checkTCP(host:port:timeout:)` — TCP check, 5-second timeout.

### Adding UI Features
- Menu bar items: Modify StatusMenuView
- Settings: Extend SettingsView
- Remember to update AppDelegate if menu bar icon behavior changes

## Project Configuration

- **Bundle ID**: `cloud.blusa.blussh`
- **Minimum macOS**: 15.3 (some features support back to 12.0)
- **Swift Version**: 5.0
- **Development Team**: VMGQ6AAMB5
