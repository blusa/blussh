#!/usr/bin/env python3
"""blussh backend for the Omarchy shell widget.

Port of the macOS MonitoringEngine (see docs/monitoring-spec.md). The shell
widget re-runs `blussh.py check` every refresh interval, so this script is
stateless between runs: debounce streaks, confirmed states and SSH
auto-detect verdicts all live in ~/.local/state/blussh/state.json.

Standard library only, so it runs on a stock Omarchy install.
"""

import argparse
import concurrent.futures
import fcntl
import getpass
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "blussh")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "blussh")
TOKEN_FILE = os.path.join(CONFIG_DIR, "zerotier-token")

SECRET_ATTRS = ["service", "cloud.blusa.blussh", "account", "zerotier-central-token"]

TCP_TIMEOUT = 5
HTTP_TIMEOUT = 10
# A reading must repeat this many times to flip the confirmed state
CONFIRMATION_THRESHOLD = 2
# Central marks members online while seen within ~60s; give it slack for polling jitter
ZEROTIER_ONLINE_WINDOW = 300


class SourceError(Exception):
    def __init__(self, message, missing=False):
        super().__init__(message)
        self.missing = missing  # the tool isn't installed/configured at all


def host(id, name, group, group_key, address, **extra):
    h = {
        "id": id,
        "name": name,
        "group": group,
        "groupKey": group_key,
        "address": address,
        "user": None,
        "port": 22,
        "netOnline": None,
        "sshOnline": None,
        "isSSHServer": False,
        "enabled": True,
        "placeholder": False,
        "aliases": [],
        "sshAlias": None,
    }
    h.update(extra)
    return h


# MARK: - State

class State:
    """Advisory-locked JSON state shared by every invocation of this script."""

    def __init__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        self._lock = open(STATE_FILE + ".lock", "w")

    def __enter__(self):
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        try:
            with open(STATE_FILE) as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}
        for key in ("enabled", "isSSH", "confirmed", "streaks"):
            self.data.setdefault(key, {})
        return self.data

    def __exit__(self, exc_type, *_):
        if exc_type is None:
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(self.data, f, indent=1, sort_keys=True)
            os.replace(tmp, STATE_FILE)
        fcntl.flock(self._lock, fcntl.LOCK_UN)


def read_state():
    with State() as data:
        return json.loads(json.dumps(data))


# MARK: - SSH config

def ssh_config_hosts(paths):
    hosts, errors, found = [], [], False
    for path in paths:
        expanded = os.path.realpath(os.path.expanduser(path))  # GNU Stow symlinks
        try:
            with open(expanded, encoding="utf-8") as f:
                hosts.extend(parse_ssh_config(f.read()))
            found = True
        except OSError as e:
            errors.append(f"{path}: {e.strerror or e}")
    if errors:
        raise PartialResult(hosts, " · ".join(errors), missing=not found)
    return hosts


def parse_ssh_config(contents):
    hosts = []
    current = {}

    def commit():
        # A Host line may list several names ("Host devbox devbox.example.com");
        # the first non-pattern one is canonical, the rest are aliases.
        names = [n for n in current.get("host", "").split() if not re.search(r"[*?!]", n)]
        if not names:
            return
        name = names[0]
        address = current.get("hostname", name)
        try:
            port = int(current.get("port", "22"))
        except ValueError:
            port = 22
        hosts.append(host(
            f"ssh:{name}", name, "SSH Config", "0", address,
            user=current.get("user"),
            port=port,
            isSSHServer=True,
            aliases=[a.lower() for a in names + [address]],
            sshAlias=name,
        ))

    for line in contents.splitlines():
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#"):
            continue
        parts = re.split(r"\s*=\s*|\s+", trimmed, maxsplit=1)
        if len(parts) != 2:
            continue
        key, value = parts[0].lower(), parts[1].strip()
        if key == "host":
            commit()
            current = {}
        current[key] = value
    commit()
    return hosts


# MARK: - Tailscale

def tailscale_hosts():
    binary = shutil.which("tailscale")
    if not binary:
        raise SourceError("tailscale not installed", missing=True)
    try:
        out = subprocess.run([binary, "status", "--json"], capture_output=True, text=True, timeout=15)
    except subprocess.TimeoutExpired:
        raise SourceError("tailscale status timed out")
    if out.returncode != 0:
        raise SourceError((out.stderr or out.stdout).strip()[:200] or f"tailscale exited with {out.returncode}")
    try:
        root = json.loads(out.stdout)
    except ValueError:
        raise SourceError("unexpected status --json output")

    state = root.get("BackendState", "")
    if state and state != "Running":
        raise SourceError(f"Tailscale is {state.lower()}")

    tailnet = (root.get("CurrentTailnet") or {}).get("Name") or root.get("MagicDNSSuffix") or ""
    group = f"Tailscale · {tailnet}" if tailnet else "Tailscale"
    hosts = []
    for peer in (root.get("Peer") or {}).values():
        host_name = peer.get("HostName")
        if not host_name:
            continue
        dns_name = (peer.get("DNSName") or "").strip(".") or None
        # Mullvad exit nodes would flood the list with hundreds of servers
        if dns_name and dns_name.endswith(".mullvad.ts.net"):
            continue
        ips = peer.get("TailscaleIPs") or []
        address = dns_name or next((ip for ip in ips if ":" not in ip), host_name)
        short = dns_name.split(".")[0] if dns_name else host_name
        aliases = [ip.lower() for ip in ips] + [short.lower(), host_name.lower()]
        if dns_name:
            aliases.append(dns_name.lower())
        hosts.append(host(
            f"ts:{short.lower()}", short, group, "1", address,
            netOnline=bool(peer.get("Online")),
            aliases=aliases,
            os=peer.get("OS") or "",
        ))
    hosts.sort(key=lambda h: h["name"].lower())
    return hosts


# MARK: - ZeroTier

ZEROTIER_TOKEN_PATHS = [
    os.path.expanduser("~/.zeroTierOneAuthToken"),
    "/var/lib/zerotier-one/authtoken.secret",
]


def zerotier_local_token():
    denied = False
    for path in ZEROTIER_TOKEN_PATHS:
        try:
            with open(path) as f:
                return f.read().strip()
        except PermissionError:
            denied = True
        except OSError:
            pass
    if denied:
        raise SourceError("can't read authtoken.secret — run: blussh zerotier-authtoken")
    raise SourceError("ZeroTier not installed", missing=True)


def http_get(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        hint = " — invalid Central API token" if e.code in (401, 403) else ""
        raise SourceError(f"HTTP {e.code}{hint}")
    except (urllib.error.URLError, OSError) as e:
        raise SourceError(str(getattr(e, "reason", e)))
    except ValueError:
        raise SourceError("unexpected response")


def central_get(path, token):
    """Central accepts `token <t>` for classic API tokens and `Bearer <t>` for newer ones."""
    url = f"https://api.zerotier.com/api/v1{path}"
    try:
        return http_get(url, {"Authorization": f"token {token}"})
    except SourceError:
        return http_get(url, {"Authorization": f"Bearer {token}"})


def central_token():
    env = os.environ.get("BLUSSH_ZEROTIER_TOKEN")
    if env:
        return env.strip()
    if shutil.which("secret-tool"):
        try:
            out = subprocess.run(["secret-tool", "lookup", *SECRET_ATTRS], capture_output=True, text=True, timeout=5)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except subprocess.TimeoutExpired:
            pass
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip() or None
    except OSError:
        return None


def zerotier_hosts():
    auth = zerotier_local_token()
    local = {"X-ZT1-Auth": auth}
    try:
        networks = http_get("http://localhost:9993/network", local)
        self_node = http_get("http://localhost:9993/status", local).get("address")
    except SourceError as e:
        raise SourceError(f"local API: {e}")

    def placeholder(net, message):
        return host(f"zt:{net['id']}:placeholder", message, zt_group(net), "2" + net["name"], "",
                    enabled=False, placeholder=True)

    joined = [{"id": n["id"], "name": n.get("name") or "", "ok": n.get("status") == "OK"}
              for n in networks if n.get("id")]
    token = central_token()
    if not token:
        raise_partial([placeholder(n, "Set a ZeroTier Central token (blussh zerotier-token)") for n in joined],
                      "no Central API token configured")

    hosts, errors = [], []
    for net in joined:
        if not net["ok"]:
            hosts.append(placeholder(net, "Network unreachable (status not OK)"))
            continue
        try:
            hosts.extend(zerotier_members(net, token, self_node))
        except SourceError as e:
            hosts.append(placeholder(net, f"Central: {e}"))
            errors.append(f"{net['name'] or net['id']}: {e}")
    if errors:
        raise_partial(hosts, " · ".join(errors))
    return hosts


def zt_group(net):
    return f"ZeroTier · {net['name']}" if net["name"] else f"ZeroTier · {net['id']}"


def zerotier_members(net, token, self_node):
    members = central_get(f"/network/{net['id']}/member", token)
    if not isinstance(members, list):
        raise SourceError("unexpected member list response")
    now_ms = time.time() * 1000
    hosts = []
    for m in members:
        node = m.get("nodeId")
        config = m.get("config") or {}
        if not node or node == self_node or m.get("hidden") or config.get("authorized") is False:
            continue
        name = m.get("name") or node
        ips = config.get("ipAssignments") or []
        # Central renamed lastOnline -> lastSeen at some point; accept either (epoch ms)
        last_seen = m.get("lastSeen") or m.get("lastOnline") or 0
        online = last_seen > 0 and now_ms - last_seen < ZEROTIER_ONLINE_WINDOW * 1000
        hosts.append(host(
            f"zt:{net['id']}:{node}", name, zt_group(net), "2" + net["name"], ips[0] if ips else node,
            netOnline=online,
            aliases=[name.lower(), node.lower()] + [ip.lower() for ip in ips],
        ))
    hosts.sort(key=lambda h: h["name"].lower())
    return hosts


class PartialResult(SourceError):
    def __init__(self, hosts, message, missing=False):
        super().__init__(message, missing)
        self.hosts = hosts


def raise_partial(hosts, message):
    raise PartialResult(hosts, message)


# MARK: - Engine

def merge(hosts):
    """Fold ssh-config entries into the VPN host they point at."""
    vpn = [h for h in hosts if h["groupKey"] != "0"]
    ssh = [h for h in hosts if h["groupKey"] == "0"]
    index = {alias: i for i, h in enumerate(vpn) for alias in h["aliases"]}
    unmatched = []
    for s in ssh:
        i = index.get(s["address"].lower(), index.get(s["name"].lower()))
        if i is None:
            unmatched.append(s)
            continue
        vpn[i].update(user=s["user"], port=s["port"], isSSHServer=True, sshAlias=s["name"])
    return unmatched + vpn


def is_online(h):
    """VPN state gates first, then the SSH check if applicable."""
    if h["netOnline"] is not None:
        if not h["netOnline"]:
            return False
        if h["isSSHServer"] and h["sshOnline"] is not None:
            return h["sshOnline"]
        return True
    return bool(h["sshOnline"])


def ssh_command(h):
    target = h["sshAlias"] or h["address"]
    return f"ssh {h['user']}@{target}" if h["user"] else f"ssh {target}"


def check_tcp(address, port):
    try:
        with socket.create_connection((address, port), timeout=TCP_TIMEOUT):
            return True
    except OSError:
        return False


def apply_debounce(hosts, state):
    confirmed, streaks = state["confirmed"], state["streaks"]
    transitions = []
    for h in hosts:
        if not h["enabled"] or h["placeholder"]:
            continue
        current = h["online"]
        previous = confirmed.get(h["id"])
        if previous is None:
            confirmed[h["id"]] = current  # first sighting: baseline, no notification
            continue
        if current == previous:
            streaks.pop(h["id"], None)
            continue
        streak = streaks.get(h["id"])
        count = streak[1] + 1 if streak and streak[0] == current else 1
        if count >= CONFIRMATION_THRESHOLD:
            confirmed[h["id"]] = current
            streaks.pop(h["id"], None)
            transitions.append((h, current))
        else:
            streaks[h["id"]] = [current, count]
    return transitions


def notify(h, up):
    body = f"{h['group']} · {h['address']}"
    urgency = "normal" if up else "critical"
    if shutil.which("omarchy-notification-send"):
        # Omarchy's own sender renders a theme-colored glyph instead of an emoji
        title = f"{h['name']} is back up" if up else f"{h['name']} went down"
        cmd = ["omarchy-notification-send", "--app-name", "blussh", "-g", "󰒋" if up else "󰒎",
               "-u", urgency, title, body]
    else:
        title = f"🟢 {h['name']} is back up" if up else f"🔴 {h['name']} went down"
        cmd = ["notify-send", "-a", "blussh", "-u", urgency, title, body]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def run_cycle(sources, ssh_paths, notifications):
    discoverers = []
    if "ssh" in sources:
        discoverers.append(("SSH Config", lambda: ssh_config_hosts(ssh_paths)))
    if "tailscale" in sources:
        discoverers.append(("Tailscale", tailscale_hosts))
    if "zerotier" in sources:
        discoverers.append(("ZeroTier", zerotier_hosts))

    discovered, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [(name, pool.submit(fn)) for name, fn in discoverers]
        for name, future in futures:
            try:
                discovered.extend(future.result())
            except PartialResult as e:
                discovered.extend(e.hosts)
                errors.append({"source": name, "message": str(e), "missing": e.missing})
            except SourceError as e:
                errors.append({"source": name, "message": str(e), "missing": e.missing})
            except Exception as e:  # never let one source take the widget down
                errors.append({"source": name, "message": f"{type(e).__name__}: {e}", "missing": False})

        hosts = merge(discovered)
        state = read_state()

        # Apply persisted per-host overrides
        for h in hosts:
            if h["placeholder"]:
                continue
            h["enabled"] = state["enabled"].get(h["id"], True)
            if h["id"] in state["isSSH"]:
                h["isSSHServer"] = state["isSSH"][h["id"]]

        # Auto-detect SSH: first time a VPN host is seen net-online, probe its port once
        detect = [h for h in hosts if not h["placeholder"] and h["netOnline"] is True
                  and h["id"] not in state["isSSH"] and not h["isSSHServer"]]
        verdicts = {}
        for h, responds in zip(detect, pool.map(lambda h: check_tcp(h["address"], h["port"]), detect)):
            h["isSSHServer"] = responds
            h["sshOnline"] = True if responds else None
            verdicts[h["id"]] = responds

        # TCP checks; hosts the VPN reports offline are down, no point probing
        probe = [h for h in hosts if h["enabled"] and h["isSSHServer"] and not h["placeholder"]
                 and h["netOnline"] is not False and h["sshOnline"] is None]
        for h, online in zip(probe, pool.map(lambda h: check_tcp(h["address"], h["port"]), probe)):
            h["sshOnline"] = online
    for h in hosts:
        if h["isSSHServer"] and h["netOnline"] is False:
            h["sshOnline"] = False
        h["online"] = is_online(h)
        h["sshCommand"] = ssh_command(h)

    with State() as data:
        for host_id, verdict in verdicts.items():
            data["isSSH"].setdefault(host_id, verdict)  # a user override made meanwhile wins
        transitions = apply_debounce(hosts, data)

    if notifications:
        for h, up in transitions:
            notify(h, up)

    active = [h for h in hosts if h["enabled"] and not h["placeholder"]]
    online = sum(1 for h in active if h["online"])
    if not active:
        status = "none"
    elif online == len(active):
        status = "all-online"
    elif online == 0:
        status = "all-offline"
    else:
        status = "some-online"

    hosts.sort(key=lambda h: h["groupKey"])  # stable: keeps per-source order within groups
    for h in hosts:
        del h["aliases"]
    return {
        "hostname": socket.gethostname().split(".")[0].upper(),
        "status": status,
        "online": online,
        "total": len(active),
        "updated": int(time.time()),
        "hosts": hosts,
        "errors": errors,
    }


# MARK: - CLI

def cmd_check(args):
    sources = {s.strip() for s in args.sources.split(",") if s.strip()}
    ssh_paths = split_paths(args.ssh_config) or ["~/.ssh/config"]
    result = run_cycle(sources, ssh_paths, not args.no_notify)
    json.dump(result, sys.stdout, indent=None if args.compact else 2)
    sys.stdout.write("\n")


def parse_bool(value):
    if value.lower() in ("1", "true", "yes", "on"):
        return True
    if value.lower() in ("0", "false", "no", "off"):
        return False
    raise argparse.ArgumentTypeError(f"not a boolean: {value}")


def cmd_set(args):
    key = {"enabled": "enabled", "ssh": "isSSH"}[args.field]
    with State() as data:
        data[key][args.host_id] = args.value
        if key == "enabled" and args.value:
            # Re-baseline so re-enabling a host doesn't fire a stale transition
            data["confirmed"].pop(args.host_id, None)
            data["streaks"].pop(args.host_id, None)
    print("ok")


def store_central_token(token):
    """Validate and store the Central token. Returns a human-readable result or raises SourceError."""
    token = token.strip()
    if not token:
        raise SourceError("no token entered")
    if len(token) < 24:
        raise SourceError(f"token looks too short ({len(token)} chars) — paste the full API token")
    central_get("/network", token)
    if shutil.which("secret-tool"):
        out = subprocess.run(["secret-tool", "store", "--label=blussh ZeroTier Central token", *SECRET_ATTRS],
                             input=token, text=True, capture_output=True)
        if out.returncode == 0:
            return "token works — saved to the keyring"
    os.makedirs(CONFIG_DIR, exist_ok=True)
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return f"token works — saved to {TOKEN_FILE}"


def cmd_zerotier_token(args):
    if args.clear:
        if shutil.which("secret-tool"):
            subprocess.run(["secret-tool", "clear", *SECRET_ATTRS])
        try:
            os.remove(TOKEN_FILE)
        except OSError:
            pass
        print("ZeroTier Central token removed.")
        return

    if args.stdin:
        # Used by the panel: the token arrives on stdin (never in argv), result as JSON
        try:
            result = {"ok": True, "message": store_central_token(sys.stdin.read())}
        except SourceError as e:
            result = {"ok": False, "message": str(e)}
        print(json.dumps(result))
        return

    print("Create an API token at https://my.zerotier.com → Account → API Access Tokens.")
    try:
        print(store_central_token(getpass.getpass("ZeroTier Central API token: ")))
    except SourceError as e:
        sys.exit(f"Token rejected: {e}")


def cmd_doctor(args):
    """Per-source diagnostics for the panel's settings page."""
    tailscale = shutil.which("tailscale")
    ts_state = None
    if tailscale:
        try:
            out = subprocess.run([tailscale, "status", "--json"], capture_output=True, text=True, timeout=10)
            ts_state = json.loads(out.stdout).get("BackendState") if out.returncode == 0 else "Stopped"
        except (subprocess.TimeoutExpired, ValueError):
            ts_state = "Unknown"

    zt_installed = bool(shutil.which("zerotier-one") or os.path.isdir("/var/lib/zerotier-one"))
    try:
        zerotier_local_token()
        local_token = "ok"
    except SourceError as e:
        local_token = "missing" if e.missing else "denied"
    running = False
    if local_token == "ok":
        try:
            http_get("http://localhost:9993/status", {"X-ZT1-Auth": zerotier_local_token()})
            running = True
        except SourceError:
            pass

    print(json.dumps({
        "tailscale": {"binary": tailscale, "state": ts_state},
        "zerotier": {"installed": zt_installed, "running": running, "localToken": local_token,
                     "centralToken": bool(central_token())},
        "sshPaths": {p: count_ssh_hosts(p) for p in split_paths(args.ssh_config)},
    }))


def split_paths(value):
    return [p.strip() for p in value.split(",") if p.strip()]


def count_ssh_hosts(path):
    """Host count for a config file, or None when it can't be read."""
    try:
        with open(os.path.realpath(os.path.expanduser(path)), encoding="utf-8") as f:
            return len(parse_ssh_config(f.read()))
    except OSError:
        return None


def cmd_zerotier_authtoken(_args):
    """ZeroTier's local API token is root-only; zerotier-cli also honours a per-user copy."""
    target = ZEROTIER_TOKEN_PATHS[0]
    print(f"Copying /var/lib/zerotier-one/authtoken.secret to {target} (needs sudo)…")
    script = f'install -m 600 -o "$SUDO_USER" /var/lib/zerotier-one/authtoken.secret {json.dumps(target)}'
    sys.exit(subprocess.run(["sudo", "bash", "-c", script]).returncode)


def main():
    parser = argparse.ArgumentParser(prog="blussh", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="discover, probe and print host status as JSON")
    check.add_argument("--sources", default="ssh,tailscale,zerotier", help="comma-separated: ssh,tailscale,zerotier")
    check.add_argument("--ssh-config", default="~/.ssh/config", help="comma-separated ssh config paths")
    check.add_argument("--no-notify", action="store_true", help="don't send desktop notifications")
    check.add_argument("--compact", action="store_true", help="single-line JSON")
    check.set_defaults(func=cmd_check)

    setp = sub.add_parser("set", help="persist a per-host override")
    setp.add_argument("host_id")
    setp.add_argument("field", choices=["enabled", "ssh"])
    setp.add_argument("value", type=parse_bool)
    setp.set_defaults(func=cmd_set)

    zt = sub.add_parser("zerotier-token", help="store the ZeroTier Central API token")
    zt.add_argument("--clear", action="store_true")
    zt.add_argument("--stdin", action="store_true", help="read the token from stdin, print JSON")
    zt.set_defaults(func=cmd_zerotier_token)

    doc = sub.add_parser("doctor", help="print per-source diagnostics as JSON")
    doc.add_argument("--ssh-config", default="~/.ssh/config", help="comma-separated ssh config paths")
    doc.set_defaults(func=cmd_doctor)

    zta = sub.add_parser("zerotier-authtoken", help="copy ZeroTier's local authtoken so blussh can read it")
    zta.set_defaults(func=cmd_zerotier_authtoken)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
