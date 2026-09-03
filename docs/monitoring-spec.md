# blussh monitoring — platform-agnostic functional spec

This documents *what* blussh does and every external interface it touches, so the
same functionality can be reimplemented elsewhere — specifically as an
Omarchy (Arch + Hyprland) taskbar plugin for Waybar. The macOS app
(`blussh/*.swift`) is the reference implementation; design history in
`docs/superpowers/specs/2026-09-02-vpn-discovery-design.md`.

## Overview

Discover hosts from three sources, decide per-host liveness, debounce state
changes, notify on confirmed down/up transitions, render an aggregate + per-host
status UI.

```
every N seconds:
  hosts = discover(ssh_config) ∪ discover(tailscale) ∪ discover(zerotier)
  hosts = merge_ssh_config_entries_into_vpn_hosts(hosts)
  auto_detect_ssh_servers(hosts)        # once per host, persisted
  tcp_check_ssh_servers(hosts)          # concurrent, 5 s timeout
  transitions = debounce(hosts)         # 2 consecutive readings to flip
  notify(transitions)
  render(hosts)
```

## Sources

### 1. SSH config

Parse `~/.ssh/config` (resolve symlinks — dotfiles are often GNU Stow links).
Recognized keys (case-insensitive): `Host`, `HostName`, `User`, `Port`.
Skip `Host` patterns containing `*`, `?` or `!`. A block without `HostName`
uses the alias as address. These hosts are always SSH servers.

### 2. Tailscale

```
tailscale status --json
```

Relevant output shape (verified against Tailscale 1.98):

```jsonc
{
  "Self":   { "HostName": "...", "DNSName": "buster.tail32621d.ts.net.", ... },
  "MagicDNSSuffix": "tail32621d.ts.net",
  "CurrentTailnet": { "Name": "pablo.pusiol@gmail.com" },
  "Peer": {                       // map keyed by node public key
    "nodekey:...": {
      "HostName": "zorak",        // machine-reported name
      "DNSName": "zorak.tail32621d.ts.net.",   // note trailing dot — strip it
      "TailscaleIPs": ["100.78.112.90", "fd7a:..."],  // v4 first, then v6
      "OS": "linux",
      "Online": true              // control-plane liveness — this is netOnline
    }
  }
}
```

- Exclude `Self` (don't monitor the local machine).
- Display name = first label of DNSName; address = DNSName without trailing dot
  (falls back to first IPv4).
- On Linux the binary is just `tailscale` on PATH (macOS needs path detection).

### 3. ZeroTier (two APIs)

**Local service API** — which networks is this node joined to:

```
GET http://localhost:9993/network     header: X-ZT1-Auth: <authtoken>
GET http://localhost:9993/status      → {"address": "aa79fc1ded", ...}  # own node id
```

- authtoken location: Linux `/var/lib/zerotier-one/authtoken.secret` (root-owned:
  either read via sudo rule, or add user to a group, or copy it once);
  macOS `~/Library/Application Support/ZeroTier/One/authtoken.secret`.
- `/network` returns an array; per network: `id` (16-hex nwid), `name`,
  `status` (`"OK"` joined & authorized; `"NOT_FOUND"` = dead/stale network —
  show but don't query members), `assignedAddresses`.

**Central API** — member list *with names* (names exist only in Central):

```
GET https://api.zerotier.com/api/v1/network/<nwid>/member
    header: Authorization: token <api-token>     # classic tokens
    fallback: Authorization: Bearer <api-token>  # newer tokens; retry on 401/403
```

- API token from my.zerotier.com → Account → API Access Tokens (~32 chars,
  shown once at creation). Store securely (macOS: Keychain; Linux:
  `secret-tool`/file with 0600).
- Per member: `nodeId` (10-hex), `name` (may be empty → fall back to nodeId),
  `hidden` (skip if true), `config.authorized` (skip if false),
  `config.ipAssignments` (managed IPs — first one is the address),
  `lastSeen` **or** `lastOnline` (field was renamed across Central versions —
  accept either; epoch **milliseconds**).
- `netOnline` = lastSeen within the last **300 s** (Central refreshes ~every
  60 s; 5 min absorbs jitter).
- Exclude own node (compare against `/status.address`).
- Networks joined locally but not visible to the token: list the network group
  with a placeholder row, no members.

## Cross-source merge

The same machine often appears in ssh config *and* a VPN. Merge rule:

1. Build an alias index over VPN hosts: all IPs, DNS name, short name,
   machine hostname — lowercased.
2. For each ssh-config entry, look up its `HostName` (then its alias) in the
   index. On match: drop the standalone ssh entry; the VPN host inherits
   `user` + `port`, is marked as SSH server, and remembers the config alias so
   the "copy ssh command" action yields `ssh user@alias` (letting the user's
   ssh config supply keys/options).

## Liveness

Two signals per host:

- `netOnline` (bool?, VPN hosts only): what the control plane reports.
- `sshOnline` (bool?, SSH servers only): TCP connect to port 22 (or config
  port), **5 s timeout**. Skip the probe when `netOnline == false` (it's down;
  don't waste a timeout) — record `sshOnline = false`.

```
isOnline =
  netOnline == nil        → sshOnline          # pure ssh-config host
  netOnline == false      → false
  isSSHServer && sshOnline != nil → sshOnline
  otherwise               → true               # net up, not an ssh server
```

**SSH auto-detection**: the first time a VPN host is observed with
`netOnline == true` and has no persisted verdict, probe port 22 once; persist
the boolean forever (user can override per host). ssh-config hosts are always
SSH servers.

Aggregate status (enabled hosts only): all online / some online / all offline /
none — drives the bar color (green / orange / red / gray).

## Debounce + notifications

Per host, keep `confirmed` (last confirmed isOnline) and a pending streak:

- First time a host is ever seen: set `confirmed = current`, **no notification**.
- `current == confirmed`: clear streak.
- `current != confirmed`: increment streak (reset it if the pending direction
  flipped). When streak reaches **2**, set confirmed, clear streak, emit a
  transition.

Notify on each transition (only for enabled hosts):

- down: `🔴 <name> went down` — body `<group> · <address>`
- up: `🟢 <name> is back up` — same body

`confirmed` is persisted across restarts (so a change while the monitor was
off notifies once on the next run, after debounce).

## Persistence

Keyed by stable host id — survives re-discovery and renames of transient data:

| id format | example |
|---|---|
| `ssh:<alias>` | `ssh:riki.odinedge.xyz` |
| `ts:<short-name>` | `ts:zorak` |
| `zt:<nwid>:<nodeId>` | `zt:60ee7c034ac5ef42:f2433eade5` |

State to persist: `enabled` (bool, default true), `isSSHServer` (auto-detect
verdict / user override), `confirmed` (debounce state). macOS uses UserDefaults
(`hostEnabled/v2`, `hostIsSSH/v2`, `hostConfirmedState/v2`); a Linux port
should use one JSON file, e.g. `~/.local/state/blussh/state.json`.

Settings: per-source enable flags, refresh interval (5 s/10 s/1 m/5 m),
notifications on/off, ZeroTier Central token.

## Omarchy / Waybar plugin notes

Suggested shape: one script (Python fits Omarchy conventions) run by a Waybar
`custom` module, plus the same script's `--menu` mode bound to click.

- **Waybar module** (`~/.config/waybar/config.jsonc`):

  ```jsonc
  "custom/blussh": {
    "exec": "blussh-status",        // emits one JSON line
    "return-type": "json",
    "interval": 30,
    "on-click": "blussh-status --menu"
  }
  ```

  Emit: `{"text": "12/14", "tooltip": "zorak ✓\nlola ✓\nriki ✗ ...",
  "class": "all-online" | "some-online" | "all-offline"}` — style the classes
  green/orange/red in `style.css` to match the theme.

- **Notifications**: `notify-send -u critical "🔴 zorak went down" "Tailscale · zorak.tail..."`
  (Omarchy ships mako as the notification daemon — plain notify-send works).
- **Click menu**: Omarchy uses walker/wofi — pipe host list in, copy
  `ssh user@alias` of the selection to `wl-copy`.
- **State**: since Waybar re-execs the script each interval, all state
  (debounce streaks, confirmed, auto-detect verdicts) must live in the state
  file — the script is otherwise stateless.
- **Liveness nuance**: with `interval: 30` and threshold 2, a down host
  notifies after ~60 s worst-case, same as the macOS app at 30 s refresh.
- ssh config, `tailscale status --json`, ZeroTier local + Central calls are
  identical to the above; only the authtoken path and secret storage differ.
