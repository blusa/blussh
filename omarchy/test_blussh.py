#!/usr/bin/env python3
"""Tests for the ported monitoring logic: python3 omarchy/test_blussh.py"""

import os
import sys
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


if __name__ == "__main__":
    unittest.main()
