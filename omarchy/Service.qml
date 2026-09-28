import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Runs the blussh.py backend on a timer and exposes its result. All
// monitoring logic (discovery, merge, TCP checks, debounce, notifications)
// lives in the backend so it stays testable outside the shell.
Item {
  id: root

  property var settings: ({})

  property bool loaded: false
  property var hosts: []
  property var errors: []
  property string hostname: ""
  property string status: "none"   // all-online | some-online | all-offline | none
  property int online: 0
  property int total: 0
  property double updated: 0
  property string actionStatus: ""
  property string lastError: ""
  readonly property bool busy: checkProcess.running

  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("blussh.py")).replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property bool notifications: setting("notifications", true) !== false
  readonly property string sshConfigPaths: String(setting("sshConfigPaths", "~/.ssh/config") || "~/.ssh/config")
  readonly property var sources: {
    var picked = setting("sources", [])
    return picked instanceof Array && picked.length > 0 ? picked : ["ssh", "tailscale", "zerotier"]
  }

  // Per-host toggles made while a check was already running would be undone
  // by that check's (older) result; keep re-applying them until a check that
  // started after the toggle reports back.
  property var _overrides: ({})
  property double _checkStartedAt: 0
  property bool _refreshAgain: false
  property string _output: ""
  property string _error: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function refresh() {
    if (checkProcess.running) {
      _refreshAgain = true
      return
    }
    _output = ""
    _error = ""
    _checkStartedAt = Date.now()
    var command = ["python3", scriptPath, "check", "--compact",
                   "--sources", sources.join(","), "--ssh-config", sshConfigPaths]
    if (!notifications) command.push("--no-notify")
    checkProcess.command = command
    checkProcess.running = true
    watchdog.restart()
  }

  function refreshIfStale() {
    if (Date.now() - updated * 1000 > 10000) refresh()
  }

  function parse(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
    } catch (e) {
      lastError = "blussh backend returned invalid output"
      return
    }
    var next = data.hosts || []
    var overrides = {}
    for (var id in _overrides) {
      var o = _overrides[id]
      if (o.at < _checkStartedAt) continue
      overrides[id] = o
      for (var i = 0; i < next.length; i++) {
        if (next[i].id === id) next[i][o.field] = o.value
      }
    }
    _overrides = overrides
    hosts = next
    errors = data.errors || []
    hostname = String(data.hostname || "")
    status = String(data.status || "none")
    online = data.online || 0
    total = data.total || 0
    updated = data.updated || 0
    lastError = ""
    loaded = true
  }

  function sshTarget(host) {
    if (!host) return ""
    var hostPart = host.sshAlias || host.address
    return host.user ? host.user + "@" + hostPart : hostPart
  }

  function flash(message) {
    actionStatus = message
    actionStatusTimer.restart()
  }

  function copySshCommand(host) {
    if (!host || host.placeholder) return
    var text = String(host.sshCommand || "")
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    flash("Copied " + text)
  }

  function openSsh(host) {
    if (!host || host.placeholder) return
    Quickshell.execDetached(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "ssh", sshTarget(host)])
  }

  function setOverride(host, field, cliField, value) {
    if (!host || host.placeholder) return
    var overrides = {}
    for (var id in _overrides) overrides[id] = _overrides[id]
    overrides[host.id] = { field: field, value: value, at: Date.now() }
    _overrides = overrides

    var next = hosts.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id !== host.id) continue
      var copy = {}
      for (var key in next[i]) copy[key] = next[i][key]
      copy[field] = value
      if (field === "isSSHServer") copy.sshOnline = null
      next[i] = copy
    }
    hosts = next

    Quickshell.execDetached(["python3", scriptPath, "set", host.id, cliField, value ? "true" : "false"])
    delayedRefresh.restart()
  }

  function setEnabled(host, enabled) {
    setOverride(host, "enabled", "enabled", enabled)
    flash(enabled ? "Showing and monitoring " + host.name : "Hid " + host.name + " (no longer monitored)")
  }

  function setIsSSHServer(host, isSSH) {
    setOverride(host, "isSSHServer", "ssh", isSSH)
    flash((isSSH ? "SSH check on for " : "SSH check off for ") + host.name)
  }

  function setZeroTierToken() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "python3 " + Util.shellQuote(scriptPath) + " zerotier-token"])
  }

  onSourcesChanged: if (loaded) refresh()
  onSshConfigPathsChanged: if (loaded) refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 700
    onTriggered: root.refresh()
  }

  Timer {
    // A hung check (DNS that never answers, a wedged tailscaled) would
    // otherwise block every later refresh, since refresh() skips while one runs.
    id: watchdog
    interval: 60000
    onTriggered: if (checkProcess.running) checkProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: checkProcess
    running: false
    command: []
    stdout: StdioCollector { id: checkStdout; waitForEnd: true; onStreamFinished: root._output = text }
    stderr: StdioCollector { id: checkStderr; waitForEnd: true; onStreamFinished: root._error = text }
    onExited: function(exitCode) {
      watchdog.stop()
      var stdout = String(checkStdout.text || root._output || "")
      var stderr = String(checkStderr.text || root._error || "")
      if (exitCode === 0) root.parse(stdout)
      else {
        var lines = stderr.trim().split("\n")
        root.lastError = lines[lines.length - 1] || ("blussh check failed (exit " + exitCode + ")")
      }
      if (root._refreshAgain) {
        root._refreshAgain = false
        Qt.callLater(root.refresh)
      }
    }
  }
}
