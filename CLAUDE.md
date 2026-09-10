# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

blussh is a native macOS menu bar application built with SwiftUI that monitors host connectivity. It discovers hosts from SSH config files, Tailscale, and ZeroTier, shows live status in a popover, and notifies when hosts go down or come back up.

## Development Commands

### Building
```bash
# Debug build
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Debug

# Release build
xcodebuild -project blussh.xcodeproj -scheme blussh -configuration Release

# Clean build folder
xcodebuild -project blussh.xcodeproj -scheme blussh clean

# Run the app (after building)
open build/Debug/blussh.app
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

1. **AppDelegate** (`blussh/AppDelegate.swift`): Bridges SwiftUI with AppKit, manages the NSStatusItem (hostname + colored status dot).

2. **MonitoringEngine** (`blussh/MonitoringEngine.swift`): ObservableObject running the cycle: discover from enabled sources concurrently → merge ssh-config entries into matching VPN hosts → auto-detect SSH servers (one-time port-22 probe, persisted) → concurrent TCP checks → debounce (2 consecutive readings to confirm a state flip) → notify → publish.

3. **Host sources** (`HostSource` protocol returning `DiscoveryResult`):
   - `SSHConfigSource`: parses ssh config files (direct read, symlinks resolved for GNU Stow, wildcard Host patterns skipped; a multi-name `Host a a.example` line yields one host named after the first name, the rest kept as aliases)
   - `TailscaleSource`: runs `tailscale status --json` (binary auto-detected, override via `tailscaleBinaryPath` default)
   - `ZeroTierSource`: local API (`localhost:9993` + authtoken.secret) for joined networks, Central API for named members

4. **UI Layer**: `StatusMenuView` (popover; hosts grouped by source with online counts, tap-to-copy ssh command, context menu with SSH-monitoring toggle), `SettingsView`, `NotificationManager` (UNUserNotificationCenter down/up notifications).

### Key Technical Decisions

1. **Not sandboxed** (removed 2026-09): required to exec the tailscale CLI and read ZeroTier's authtoken. Only remaining entitlement is `network.client`.
2. **Liveness is two signals**: `netOnline` (what the VPN control plane reports) and `sshOnline` (TCP:22 check, 5 s timeout). `MonitoredHost.isOnline` combines them.
3. **Stable host IDs** (`ssh:<host>`, `ts:<name>`, `zt:<nwid>:<nodeId>`) key persisted per-host state in UserDefaults: `hostEnabled/v2`, `hostIsSSH/v2`, `hostConfirmedState/v2`.
4. **Cross-source merge**: ssh-config entries whose HostName matches a VPN host's IP/DNS alias merge into it, contributing user/port/alias so the copied command stays `ssh user@alias`.
5. **ZeroTier Central token** lives in Keychain (`KeychainHelper`, service `cloud.blusa.blussh`, account `zerotier-central-token`).

### Testing without a test target
`MonitoringEngine.merge` and `applyDebounce` are internal (not private) so they
can be smoke-tested by compiling the sources with
`swiftc -parse-as-library blussh/*.swift <harness>.swift` plus a small `@main`
async harness (UI files excluded).

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
- **Development Team**: VMGQ6AAMB5KEEP READING at CLAUDE-ARCHON.md
