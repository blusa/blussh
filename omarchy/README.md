# blussh for Omarchy

Omarchy shell (Quickshell) bar widget with the same monitoring as the macOS
app: hosts discovered from your **ssh config**, **Tailscale** and **ZeroTier**,
live status in a keyboard-friendly panel, and notifications when a host goes
down or comes back up.

## Install

```bash
omarchy/install.sh          # copy into ~/.config/omarchy/plugins/blusa.blussh
omarchy/install.sh --link   # symlink instead, for development
```

This adds the widget to the right side of the bar (move it with
`omarchy bar move blusa.blussh --section center`) and links the backend CLI
as `~/.local/bin/blussh`.

A symlinked plugin doesn't hot-reload: after editing QML, run
`omarchy restart shell`.

## Using it

Like the macOS menu bar item, the bar shows this machine's name and a status
dot (`PINKY ●`): green when every monitored host is up, orange when some are
down, red when all are down, dimmed when nothing is monitored. The colors come
from the theme's `green`/`orange`/`red`, falling back to classic
traffic-light colors on grayscale themes so the dot stays readable. Left click
opens the panel; middle or right click refreshes.

In the panel, click a host to copy its ssh command, click the terminal button
to open an ssh session, or right-click for more. Keyboard:

| Key | Action |
|---|---|
| `j` / `k`, arrows | move cursor |
| `enter` / `space` / `c` | copy ssh command |
| `o` | open ssh session in a terminal |
| `l` / right arrow | actions menu |
| `x` | hide the host (stops monitoring it) / show it again |
| `.` | show or hide the hidden hosts |
| `,` | settings |
| `s` | toggle the SSH port check for the host |
| `r` | refresh |
| `esc` | close |

### Settings

The gear button (or `,`) opens settings inside the panel, like the macOS
Settings sheet:

- **Sources**: turn ssh config, Tailscale and ZeroTier on or off. Add ssh
  config files by path or with **Browse** (Omarchy's file chooser), remove
  them, and see each file's host count (or "not found").
- **ZeroTier**: shows whether it is installed and running, with buttons to
  install it, start the service, grant blussh access to its local token, and
  paste + verify the Central API token.
- **Behavior**: notifications, hide hidden hosts, refresh interval.

They are stored in this widget's entry in `~/.config/omarchy/shell.json`, so
the bar settings panel and `omarchy bar set blusa.blussh <key> <value>` see
the same values.

### Hiding hosts

"Hide host" in the actions menu (or `x`) hides a host you don't care about
and stops monitoring and notifying for it. The eye button in the header shows
how many are hidden and reveals them (dimmed, marked "hidden") so you can
bring one back.

## ZeroTier

Two tokens are needed, as on macOS:

- **Local service token**: `/var/lib/zerotier-one/authtoken.secret` is
  root-only. `blussh zerotier-authtoken` copies it to `~/.zeroTierOneAuthToken`
  (the per-user location `zerotier-cli` also reads).
- **Central API token** for member names: `blussh zerotier-token` prompts for
  it, verifies it, and stores it in the keyring via `secret-tool` (service
  `cloud.blusa.blussh`, account `zerotier-central-token`), or in
  `~/.config/blussh/zerotier-token` (0600) when there is no keyring. The
  ZeroTier placeholder row in the panel has a key button that runs this, and
  the settings screen has a field for it.

## How it works

`blussh.py` (Python stdlib only) is the engine, a port of `MonitoringEngine`
following [`docs/monitoring-spec.md`](../docs/monitoring-spec.md): discover →
merge ssh-config entries into VPN hosts → one-time SSH auto-detect → TCP
checks (5 s) → debounce (2 consecutive readings) → notify via
`omarchy-notification-send`. The widget (`Service.qml`) runs
`blussh.py check` every refresh interval and renders the JSON it prints.

Since each run is a fresh process, all state lives in
`~/.local/state/blussh/state.json`: per-host `enabled` and `isSSH` overrides,
debounce `confirmed` states and pending `streaks`, keyed by the same host ids
as macOS (`ssh:<alias>`, `ts:<name>`, `zt:<nwid>:<nodeId>`).

```bash
blussh check --no-notify        # print status JSON without notifying
blussh set ts:zorak enabled false
python3 omarchy/test_blussh.py  # parser, merge, liveness and debounce tests
```

Differences from macOS: Mullvad exit nodes are left out of the Tailscale
group, and sources that aren't installed are only reported when you pick them
explicitly in the settings.
