# blussh — VPN host discovery (Tailscale + ZeroTier) + notifications

Date: 2026-09-02. Status: approved (sections 1–2 explicitly; section 3 delegated).

## Goal

Discover monitored hosts automatically from Tailscale (MagicDNS) and ZeroTier
(networks the local node has joined), alongside the existing SSH config file
source. Notify when a host goes down or comes back up.

## Decisions (from brainstorm)

- **Sandbox removed** — personal app, not App Store. Enables local CLI/API access.
- **Three sources**: SSH config + Tailscale + ZeroTier, each toggleable.
- **Liveness = combined**: network-reported online state as primary signal, plus a
  TCP:22 check for hosts marked as SSH servers.
- **SSH-server marking = auto-detect**: first time a host is seen net-online, probe
  port 22 once; result persisted, user can override per host.
- **Notifications with debounce**: notify only on state changes confirmed by 2
  consecutive checks. Only enabled hosts. Both down and up transitions.
- **ZeroTier names via Central API** (token in Keychain). Local API
  (`localhost:9993`) determines which networks to list; Central lists members.
- **Architecture: pluggable sources** — `HostSource` protocol with three
  implementations, unified by a `MonitoringEngine`.

## Data model

```swift
struct MonitoredHost {
    let id: String        // stable: "ssh:<host>", "ts:<hostname>", "zt:<nwid>:<nodeId>"
    let name: String
    let origin: HostOrigin    // .sshConfig | .tailscale(tailnet) | .zerotier(nwid, nwName)
    let address: String   // MagicDNS name / ZT assigned IP / config HostName
    let user: String?     // from ssh config (direct or merged)
    let port: Int
    var netOnline: Bool?  // nil for pure ssh-config hosts
    var sshOnline: Bool?  // nil when not an SSH server
    var isSSHServer: Bool
    var isEnabled: Bool
}
// isOnline = (netOnline ?? true) && (sshOnline ?? (netOnline != nil ? true : false))
//   - VPN host, not SSH server: netOnline
//   - VPN host, SSH server: netOnline && sshOnline
//   - ssh-config host: sshOnline
```

## Sources

### TailscaleSource
`tailscale status --json` via Process. Binary auto-detected among
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/usr/local/bin/tailscale`,
`/opt/homebrew/bin/tailscale`; manual override in Settings. Parses `Peer` map
(`HostName`, `DNSName`, `Online`, `TailscaleIPs`); excludes `Self`. Verified on
Buster (Tailscale 1.98). `address` = DNSName minus trailing dot.

### ZeroTierSource
1. Local API `GET http://localhost:9993/network` + `/status`, header `X-ZT1-Auth`
   from `~/Library/Application Support/ZeroTier/One/authtoken.secret` → joined
   networks (id, name, status) and own node address (for self-exclusion).
2. Central `GET https://api.zerotier.com/api/v1/network/{id}/member`, header
   `Authorization: token <t>`. Member: `nodeId`, `name`, `config.ipAssignments`,
   `lastSeen`/`lastOnline` (epoch ms — parse both, schema changed across versions).
   `netOnline` = seen within last 5 minutes. Skips hidden members and self.
- Networks joined but not visible with the token (or local status ≠ OK, e.g. dead
  NOT_FOUND networks) are listed as a group with an explanatory placeholder row.

### SSHConfigSource
Existing parser extracted to its own type. Reads paths from `sshConfigFilePaths`
directly (no security-scoped bookmarks — sandbox is gone), resolving symlinks
(GNU Stow). Skips wildcard `Host` patterns (`*`, `?`, `!`).

### Cross-source merge
If an ssh-config entry's HostName matches a discovered VPN host (by IP, MagicDNS
name, or name), the entries merge: the host lives in the VPN group, is marked
`isSSHServer`, and inherits `user`/`port` from the config (improves tap-to-copy:
`ssh user@host`). Unmatched config entries remain in the SSH Config group.

## Engine

`MonitoringEngine` (ObservableObject, replaces `SSHService`): timer → cycle:
1. Discover from enabled sources concurrently (async/await).
2. Merge + apply persisted per-host state (enabled, isSSHServer override).
3. Auto-detect SSH (first time net-online, probe 22 once, persist).
4. TCP checks concurrently (TaskGroup), 5 s timeout, port from config or 22.
5. Debounce: per-host confirmed state + streak counter; a differing reading must
   repeat 2× to become confirmed. First sighting sets baseline silently.
6. Notify confirmed transitions via UNUserNotificationCenter (toggleable).
7. Publish to UI + recompute GlobalStatus (enabled hosts only).

Persistence: UserDefaults dictionaries keyed by stable id (`hostEnabled/v2`,
`hostIsSSH/v2`, `hostConfirmedState/v2`). ZT Central token in Keychain
(service `cloud.blusa.blussh`, account `zerotier-central-token`).

## UI

- Menu: hosts grouped by origin — "SSH Config", "Tailscale · <tailnet>",
  "ZeroTier · <network>" — header shows online/total count per group.
- Row: name + `user@address` subtitle; net status dot (green/red/gray-disabled);
  small `ssh` badge for SSH servers, tinted by sshOnline (net up + ssh down ⇒
  orange overall). Tap to copy ssh command (kept). Per-host enable toggle (kept).
- Menu-bar item: keeps aggregate color logic; adopts the in-progress hostname +
  `pc` icon style found uncommitted on main (typo `}5` fixed).
- Settings: Sources section (SSH paths as today; Tailscale toggle + binary path;
  ZeroTier toggle + Central token SecureField), Notifications toggle, refresh
  frequency and Launch at Login as today.

## Errors

Any source failing (CLI missing, daemon down, token invalid, network error)
degrades gracefully: that source contributes no hosts and a short error string
shown in its group header / Settings; other sources unaffected. No crash paths.

## Out of scope

Historic uptime, latency metrics, SSH auth checks, per-host custom ports for
VPN-only hosts, watching config file changes.
