# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

blussh is a native macOS menu bar application built with SwiftUI that monitors SSH server connectivity. It's a sandboxed app that parses SSH config files and provides real-time connection status updates.

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

### Core Architecture Pattern
The app follows MVVM with Combine for reactive state management:

1. **AppDelegate** (`blussh/AppDelegate.swift`): Bridges SwiftUI with AppKit, manages the NSStatusItem (menu bar icon), and coordinates between the SSHService and UI components.

2. **SSHService** (`blussh/SSHService.swift`): The core business logic as an ObservableObject. Handles:
   - SSH config file parsing with security-scoped bookmarks
   - TCP connectivity testing using Network framework (5-second timeout)
   - Background monitoring with configurable intervals
   - Server state persistence in UserDefaults

3. **UI Layer**: SwiftUI views that observe SSHService:
   - StatusMenuView: Main popover interface with server list
   - SettingsView: Configuration for file paths and refresh intervals

### Key Technical Decisions

1. **File Access Strategy**: Uses security-scoped bookmarks to maintain file access across launches. Resolves symlinks before creating bookmarks (crucial for dotfiles managed with GNU Stow).

2. **Connection Testing**: Uses Network framework's TCP connectivity check rather than SSH authentication - faster and doesn't require credentials.

3. **State Management**: 
   - Global state in SSHService as @Published properties
   - Per-server enabled states stored in UserDefaults
   - Combine publishers for reactive updates to menu bar icon

4. **Background Processing**: Network operations run on `DispatchQueue.global()` with UI updates dispatched to main queue.

### Security & Sandboxing

The app is fully sandboxed with minimal entitlements:
- `com.apple.security.app-sandbox`: Required for Mac App Store
- `com.apple.security.files.user-selected.read-write`: For SSH config file access
- `com.apple.security.network.client`: For TCP connectivity testing

### Important Implementation Notes

1. **SSH Config Parsing**: Custom parser handles standard directives (Host, HostName, User, Port). Located in SSHService.parseSSHConfig().

2. **Status Icon Logic**: AppDelegate.updateStatusItemIcon() determines icon color based on aggregate server status (green/orange/red/gray).

3. **Refresh Timing**: Configurable intervals (5s, 10s, 1m, 5m) managed by Timer in SSHService.startMonitoring().

4. **Launch at Login**: Uses ServiceManagement framework (SettingsView handles registration).

## Common Development Tasks

### Adding New SSH Config Directives
Modify `SSHService.parseSSHConfig()` to handle additional SSH config options.

### Changing Connection Test Logic
Update `SSHService.checkConnection()` - currently uses TCP port check with 5-second timeout.

### Adding UI Features
- Menu bar items: Modify StatusMenuView
- Settings: Extend SettingsView
- Remember to update AppDelegate if menu bar icon behavior changes

### Debugging Connection Issues
Look for connection logs in `SSHService.checkConnection()` and timeout handling in the Network framework connection setup.

## Project Configuration

- **Bundle ID**: `cloud.blusa.blussh`
- **Minimum macOS**: 15.3 (some features support back to 12.0)
- **Swift Version**: 5.0
- **Development Team**: VMGQ6AAMB5