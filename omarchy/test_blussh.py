#!/usr/bin/env python3
"""Tests for the ported monitoring logic: python3 omarchy/test_blussh.py"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blussh  # noqa: E402

SSH_CONFIG = """
Host *
  ServerAliveInterval 30

Host devbox devbox.example.com
  HostName 100.64.0.7
  User pablo
  Port 2222

Host riki
  HostName=riki.example.xyz
  User root

# comment
Host !negated
  HostName nowhere
"""


def ts_host(name, ip, online):
    return blussh.host(f"ts:{name}", name, "Tailscale", "1", f"{name}.tail.ts.net",
                       netOnline=online, aliases=[ip, name, f"{name}.tail.ts.net"])


class ParseTests(unittest.TestCase):
    def test_multi_name_and_patterns(self):
        hosts = blussh.parse_ssh_config(SSH_CONFIG)
        self.assertEqual([h["id"] for h in hosts], ["ssh:devbox", "ssh:riki"])
        devbox = hosts[0]
        self.assertEqual(devbox["address"], "100.64.0.7")
        self.assertEqual(devbox["port"], 2222)
        self.assertEqual(devbox["user"], "pablo")
        self.assertIn("devbox.example.com", devbox["aliases"])
        self.assertEqual(hosts[1]["address"], "riki.example.xyz")  # "Key=Value" form

    def test_merge_into_vpn_host(self):
        ssh = blussh.parse_ssh_config(SSH_CONFIG)
        merged = blussh.merge(ssh + [ts_host("devbox", "100.64.0.7", True)])
        self.assertEqual([h["id"] for h in merged], ["ssh:riki", "ts:devbox"])
        devbox = merged[1]
        self.assertTrue(devbox["isSSHServer"])
        self.assertEqual((devbox["user"], devbox["port"], devbox["sshAlias"]), ("pablo", 2222, "devbox"))
        self.assertEqual(blussh.ssh_command(devbox), "ssh pablo@devbox")


class LivenessTests(unittest.TestCase):
    def test_is_online(self):
        h = ts_host("a", "1.1.1.1", False)
        self.assertFalse(blussh.is_online(h))
        h.update(netOnline=True)
        self.assertTrue(blussh.is_online(h))
        h.update(isSSHServer=True, sshOnline=False)
        self.assertFalse(blussh.is_online(h))
        pure = blussh.host("ssh:x", "x", "SSH Config", "0", "x", isSSHServer=True, sshOnline=True)
        self.assertTrue(blussh.is_online(pure))


class DebounceTests(unittest.TestCase):
    def reading(self, state, online):
        h = ts_host("a", "1.1.1.1", online)
        h["online"] = online
        return [(x["id"], up) for x, up in blussh.apply_debounce([h], state)]

    def test_needs_two_consecutive_readings(self):
        state = {"confirmed": {}, "streaks": {}}
        self.assertEqual(self.reading(state, True), [])      # baseline, no notification
        self.assertEqual(self.reading(state, False), [])     # first down reading
        self.assertEqual(self.reading(state, True), [])      # blip recovered, streak cleared
        self.assertEqual(self.reading(state, False), [])
        self.assertEqual(self.reading(state, False), [("ts:a", False)])
        self.assertEqual(self.reading(state, False), [])
        self.assertEqual(self.reading(state, True), [])
        self.assertEqual(self.reading(state, True), [("ts:a", True)])


# Trimmed from what `https://<host>.<tailnet>.ts.net/` serves on a real T3 Code box
T3_HTML = """<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="manifest" href="/manifest.webmanifest" />
    <script>
      const CUSTOM_THEMES_STORAGE_KEY = "t3code:themes:v1";
    </script>
    <title>T3 Code (Beta)</title>
"""

# A pairing token shaped like the real ones; it must never leave t3_pair()
FAKE_TOKEN = "Q7XK2MWP9ZRB"
PAIR_OUTPUT = f"""Pairing with BRAK (http://127.0.0.1:3773).

█▀▀▀▀▀█ ▄▄▀ █▀▀▀▀▀█

\x1b[1mPairing URL:\x1b[0m https://brak.tail.ts.net/pair#token={FAKE_TOKEN}
App link: t3code://pair?pairingUrl=https%3A%2F%2Fbrak.tail.ts.net%2Fpair%23token%3D{FAKE_TOKEN}
Token: {FAKE_TOKEN}
Expires: 2026-11-11T11:40:00.000Z
"""


class T3DetectionTests(unittest.TestCase):
    def test_t3_page(self):
        self.assertTrue(blussh.is_t3_page(200, "text/html; charset=utf-8", T3_HTML))
        # Older builds are titled "T3 Code (Alpha)"
        self.assertTrue(blussh.is_t3_page(200, "text/html", "<title>T3 Code (Alpha)</title>"))

    def test_other_web_apps_are_not_t3(self):
        self.assertFalse(blussh.is_t3_page(200, "application/json", '{"status": "ok"}'))
        self.assertFalse(blussh.is_t3_page(200, "text/html", "<title>Grafana</title>"))
        self.assertFalse(blussh.is_t3_page(302, "text/html", "<title>302 Found</title>"))
        self.assertFalse(blussh.is_t3_page(404, "text/html", T3_HTML))

    def test_tailscale_hosts_get_their_magicdns_name(self):
        status = {
            "MagicDNSSuffix": "tail.ts.net",
            "Self": {"HostName": "dexter", "DNSName": "dexter.tail.ts.net."},
            "Peer": {
                "a": {"HostName": "brak", "DNSName": "brak.tail.ts.net.", "TailscaleIPs": ["100.1.1.1"], "Online": True},
                "b": {"HostName": "box", "DNSName": "", "TailscaleIPs": ["100.1.1.2"], "Online": True},
            },
        }
        hosts, me = blussh.parse_tailscale_status(status)
        self.assertEqual({h["name"]: h["magicDNS"] for h in hosts}, {"brak": "brak.tail.ts.net", "box": None})
        self.assertEqual((me["id"], me["magicDNS"]), ("ts:dexter", "dexter.tail.ts.net"))


class T3ProbeTargetTests(unittest.TestCase):
    def test_peers_once_self_every_cycle(self):
        peer = blussh.host("ts:brak", "brak", "Tailscale", "1", "brak.t.ts.net", netOnline=True, magicDNS="brak.t.ts.net")
        me = blussh.host("ts:dexter", "dexter", "Tailscale", "1", "dexter.t.ts.net", netOnline=True,
                         magicDNS="dexter.t.ts.net", isSelf=True)
        fresh = {"isT3": {}}
        self.assertEqual([h["id"] for h in blussh.t3_probe_targets([peer], me, fresh)], ["ts:brak", "ts:dexter"])
        # brak has a persisted verdict; this machine never gets one, so it's probed again
        seen = {"isT3": {"ts:brak": False}}
        self.assertEqual([h["id"] for h in blussh.t3_probe_targets([peer], me, seen)], ["ts:dexter"])
        # ...unless the user set an override for it
        overridden = {"isT3": {"ts:brak": False, "ts:dexter": True}}
        self.assertEqual(blussh.t3_probe_targets([peer], me, overridden), [])


class PairingTests(unittest.TestCase):
    def test_extracts_only_the_pairing_url(self):
        url = blussh.extract_pairing_url(PAIR_OUTPUT, "brak.tail.ts.net")
        self.assertEqual(url, f"https://brak.tail.ts.net/pair#token={FAKE_TOKEN}")

    def test_local_url_is_rewritten_to_magicdns(self):
        out = f"Pairing URL: http://192.168.1.20:3773/pair#token={FAKE_TOKEN}\n"
        self.assertEqual(blussh.extract_pairing_url(out, "brak.tail.ts.net"),
                         f"https://brak.tail.ts.net/pair#token={FAKE_TOKEN}")

    def test_no_url_in_output(self):
        self.assertIsNone(blussh.extract_pairing_url("Error: server not running\n", "brak.tail.ts.net"))

    def test_redact(self):
        redacted = blussh.redact(PAIR_OUTPUT)
        self.assertNotIn(FAKE_TOKEN, redacted)
        self.assertIn("Pairing with BRAK", redacted)

    def fake_run(self, stdout, returncode=0, stderr=""):
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, returncode, stdout, stderr)
        return run, calls

    def test_t3_pair_copies_url_and_reports_without_token(self):
        run, calls = self.fake_run(PAIR_OUTPUT)
        copied = []
        result = blussh.t3_pair("brak", "brak.tail.ts.net", "dexter", run=run, copy=copied.append)
        self.assertTrue(result["ok"])
        self.assertEqual(copied, [f"https://brak.tail.ts.net/pair#token={FAKE_TOKEN}"])
        self.assertNotIn(FAKE_TOKEN, json.dumps(result))
        self.assertEqual(calls[0][:4], ["ssh", "-o", "BatchMode=yes", "-o"])
        self.assertIn("brak", calls[0])

    def test_t3_pair_failure_never_leaks_the_token(self):
        # e.g. a stray token on stderr from a failing run
        run, _ = self.fake_run("", 1, f"boom: token={FAKE_TOKEN}\nToken: {FAKE_TOKEN}\n")
        copied = []
        result = blussh.t3_pair("brak", "brak.tail.ts.net", "dexter", run=run, copy=copied.append)
        self.assertFalse(result["ok"])
        self.assertEqual(copied, [])
        self.assertNotIn(FAKE_TOKEN, json.dumps(result))

    def test_qr_mode_returns_an_svg_and_copies_nothing(self):
        run, _ = self.fake_run(PAIR_OUTPUT)
        encoded, copied = [], []

        def render(url):
            encoded.append(url)
            return '<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>'
        result = blussh.t3_pair("brak", "brak.tail.ts.net", "dexter", run=run, copy=copied.append,
                                qr=True, render_qr=render)
        self.assertTrue(result["ok"])
        self.assertTrue(result["qrSvg"].startswith("<svg"))
        self.assertEqual(encoded, [f"https://brak.tail.ts.net/pair#token={FAKE_TOKEN}"])
        self.assertEqual(copied, [])
        # The token is only inside the QR's modules, never as text
        self.assertNotIn(FAKE_TOKEN, json.dumps(result))

    @unittest.skipUnless(shutil.which("qrencode"), "qrencode not installed")
    def test_render_qr_with_qrencode(self):
        svg = blussh.render_qr(f"https://brak.tail.ts.net/pair#token={FAKE_TOKEN}")
        self.assertIn("<svg", svg)
        self.assertNotIn(FAKE_TOKEN, svg)

    def test_link_environment_redeems_the_code_locally(self):
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            out = PAIR_OUTPUT if cmd[0] == "ssh" else "Linked BRAK (8984aa78) with auto access, until 2026-12-11.\n"
            return subprocess.CompletedProcess(cmd, 0, out, "")
        result = blussh.t3_link("brak", "brak.tail.ts.net", "dexter", "auto", run=run, local_t3="/x/t3")
        self.assertTrue(result["ok"], result)
        self.assertEqual(calls[1], ["/x/t3", "environment", "link", "https://brak.tail.ts.net",
                                    "--pairing-code", FAKE_TOKEN, "--access", "auto"])
        self.assertNotIn(FAKE_TOKEN, json.dumps(result))

    def test_link_environment_failure_never_leaks_the_token(self):
        def run(cmd, **kwargs):
            if cmd[0] == "ssh":
                return subprocess.CompletedProcess(cmd, 0, PAIR_OUTPUT, "")
            return subprocess.CompletedProcess(cmd, 1, "", f"Error: code {FAKE_TOKEN} is unknown\n")
        result = blussh.t3_link("brak", "brak.tail.ts.net", "dexter", "auto", run=run, local_t3="/x/t3")
        self.assertFalse(result["ok"])
        self.assertNotIn(FAKE_TOKEN, json.dumps(result))

    def test_link_environment_rejects_unknown_access(self):
        result = blussh.t3_link("brak", "brak.tail.ts.net", "dexter", "root", run=None, local_t3="/x/t3")
        self.assertFalse(result["ok"])

    def test_local_pair_runs_without_ssh(self):
        run, calls = self.fake_run(PAIR_OUTPUT)
        blussh.t3_pair(None, "brak.tail.ts.net", "dexter", run=run, copy=lambda _: None)
        self.assertEqual(calls[0][:2], ["bash", "-lc"])


def stub(directory, name, body):
    path = os.path.join(directory, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(path, 0o755)


class RemoteScriptTests(unittest.TestCase):
    """Runs the scripts blussh sends over ssh against stub binaries."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.home)
        os.makedirs(self.bin)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_script(self, script, path):
        env = {"HOME": self.home, "PATH": path}
        return subprocess.run(["/bin/bash", "-c", script], env=env, capture_output=True, text=True)

    def t3_stub(self, directory, tag, fail_tailscale=False):
        os.makedirs(directory, exist_ok=True)
        check = 'case "$*" in *--tailscale*) echo "no tailscale" >&2; exit 1;; esac\n' if fail_tailscale else ""
        stub(directory, "t3", check + f'echo "{tag} $*"')

    def pair(self):
        # /usr/bin:/bin for grep/cut only; the test environment has no t3 or npx there
        return self.run_script(blussh.t3_pair_script("dexter"), f"{self.bin}:/usr/bin:/bin")

    def test_script_survives_any_login_shell(self):
        # fish treats backslashes inside single quotes as escapes
        self.assertNotIn("\\", blussh.t3_pair_script("dexter"))

    def test_prefers_t3_on_path(self):
        self.t3_stub(self.bin, "path")
        self.t3_stub(os.path.join(self.home, ".local/bin"), "local")
        self.assertEqual(self.pair().stdout.strip(), "path pair --tailscale --ttl 1h --label dexter")

    def test_then_local_bin(self):
        self.t3_stub(os.path.join(self.home, ".local/bin"), "local")
        self.t3_stub(os.path.join(self.home, ".t3/runtime/versions/0.1.8"), "runtime")
        self.assertEqual(self.pair().stdout.strip(), "local pair --tailscale --ttl 1h --label dexter")

    def test_then_runtime_active_version(self):
        runtime = os.path.join(self.home, ".t3/runtime")
        self.t3_stub(os.path.join(runtime, "versions/0.1.7"), "v0.1.7")
        self.t3_stub(os.path.join(runtime, "versions/0.1.8"), "v0.1.8")
        stub(self.bin, "npx", 'echo "npx $*"')
        with open(os.path.join(runtime, "service-state.json"), "w") as f:
            f.write('{\n  "protocol": 3,\n  "activeVersion": "0.1.7"\n}\n')
        self.assertEqual(self.pair().stdout.strip(), "v0.1.7 pair --tailscale --ttl 1h --label dexter")

    def test_then_npx(self):
        stub(self.bin, "npx", 'echo "npx $*"')
        self.assertEqual(self.pair().stdout.strip(), "npx -y t3 pair --tailscale --ttl 1h --label dexter")

    def test_retries_without_tailscale(self):
        self.t3_stub(self.bin, "path", fail_tailscale=True)
        out = self.pair()
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout.strip(), "path pair --ttl 1h --label dexter")

    def test_t3_missing(self):
        out = self.pair()
        self.assertEqual(out.returncode, 127)
        self.assertIn("t3 not found", out.stderr)

    def test_label_is_quoted(self):
        self.t3_stub(self.bin, "path")
        out = self.run_script(blussh.t3_pair_script("it's me; rm -rf ~"), f"{self.bin}:/usr/bin:/bin")
        self.assertEqual(out.stdout.strip(), "path pair --tailscale --ttl 1h --label it's me; rm -rf ~")

    def monitor(self, *available):
        for name in available:
            stub(self.bin, name, f"echo {name}")
        return self.run_script(blussh.MONITOR_SCRIPT, self.bin).stdout.strip()

    def test_monitor_prefers_btop_then_htop_then_top(self):
        self.assertEqual(self.monitor("btop", "htop", "top"), "btop")
        os.remove(os.path.join(self.bin, "btop"))
        self.assertEqual(self.monitor(), "htop")
        os.remove(os.path.join(self.bin, "htop"))
        self.assertEqual(self.monitor(), "top")

    def test_monitor_command_runs_over_a_tty(self):
        h = blussh.host("ts:brak", "brak", "Tailscale", "1", "brak.tail.ts.net", user="pablo", sshAlias="brak")
        cmd = blussh.monitor_command(h)
        self.assertEqual(cmd[:3], ["ssh", "-t", "pablo@brak"])
        self.assertEqual(shlex.split(cmd[3]), ["sh", "-lc", blussh.MONITOR_SCRIPT])


if __name__ == "__main__":
    unittest.main()
