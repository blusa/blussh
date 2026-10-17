import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// In-panel settings, the counterpart of the macOS SettingsView. Values are
// written back into this widget's bar entry (shell.json) through the panel's
// saveSetting(), so they stay in sync with the bar settings panel.
Column {
  id: root

  required property var panel
  required property var service

  readonly property color foreground: panel.foreground
  readonly property color dim: panel.dim
  readonly property string fontFamily: panel.fontFamily
  readonly property var enabledSources: service.sources
  readonly property var sshPaths: String(service.sshConfigPaths).split(",").map(function(p) { return p.trim() }).filter(function(p) { return p !== "" })

  property var doctor: null
  property string tokenStatus: ""
  property bool tokenOk: false
  property string newPath: ""

  spacing: Style.space(12)

  function refreshDoctor() {
    if (!doctorProcess.running) doctorProcess.running = true
  }

  function sourceEnabled(name) { return enabledSources.indexOf(name) !== -1 }

  function setSource(name, on) {
    var all = ["ssh", "tailscale", "zerotier"]
    var next = all.filter(function(s) { return s === name ? on : sourceEnabled(s) })
    // Every source on is stored as "all" (empty), matching the bar settings default
    panel.saveSetting("sources", next.length === all.length ? [] : next)
  }

  function savePaths(paths) {
    panel.saveSetting("sshConfigPaths", paths.join(", "))
  }

  function addPath(path) {
    var trimmed = String(path || "").trim()
    if (trimmed === "" || sshPaths.indexOf(trimmed) !== -1) return
    savePaths(sshPaths.concat([trimmed]))
    newPath = ""
    pathField.text = ""
  }

  function removePath(path) {
    savePaths(sshPaths.filter(function(p) { return p !== path }))
  }

  function saveToken() {
    var token = String(tokenField.text || "").trim()
    if (token === "" || tokenProcess.running) return
    tokenStatus = "Testing…"
    tokenOk = false
    tokenProcess.token = token
    tokenProcess.running = true
  }

  function openTerminal(command) {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", command])
    panel.close()
  }

  readonly property string script: Util.shellQuote(service.scriptPath)

  Component.onCompleted: refreshDoctor()
  onSshPathsChanged: refreshDoctor()

  function pathInfo(path) {
    var paths = doctor ? doctor.sshPaths : null
    if (!paths || !(path in paths)) return ""
    var n = paths[path]
    if (n === null) return "not found"
    return n === 1 ? "1 host" : n + " hosts"
  }
  onVisibleChanged: if (visible) refreshDoctor()

  // ── Sources ────────────────────────────────────────────────────────────

  PanelSectionHeader { text: "SOURCES"; foreground: root.foreground; fontFamily: root.fontFamily }

  Toggle {
    width: parent.width
    label: "SSH config files"
    description: root.sshPaths.length === 1 ? "1 file" : root.sshPaths.length + " files"
    checked: root.sourceEnabled("ssh")
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.setSource("ssh", !checked)
  }

  Column {
    visible: root.sourceEnabled("ssh")
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.sshPaths
      RowLayout {
        required property var modelData
        width: parent.width
        spacing: Style.space(8)
        Text {
          text: "󰈙"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Layout.leftMargin: Style.space(12)
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: modelData
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }
        Text {
          readonly property string info: root.pathInfo(modelData)
          text: info
          color: info === "not found" ? root.panel.downColor : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        PanelActionButton {
          iconText: "󰩺"
          tooltipText: "Remove"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.removePath(modelData)
        }
      }
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      TextField {
        id: pathField
        Layout.fillWidth: true
        foreground: root.foreground
        placeholderText: "~/.ssh/config.d/work"
        onTextChanged: root.newPath = text
        onAccepted: root.addPath(text)
      }
      PanelActionButton {
        iconText: "󰈞"
        tooltipText: "Browse…"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: if (!pickProcess.running) pickProcess.running = true
      }
      PanelActionButton {
        iconText: "󰐕"
        tooltipText: "Add file"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.newPath.trim() !== ""
        opacity: enabled ? 1 : 0.4
        onClicked: root.addPath(root.newPath)
      }
    }
  }

  Toggle {
    width: parent.width
    label: "Tailscale"
    description: {
      var ts = root.doctor ? root.doctor.tailscale : null
      if (!ts) return "Checking…"
      if (!ts.binary) return "Not installed — omarchy install service tailscale"
      return ts.binary + " · " + String(ts.state || "unknown").toLowerCase()
    }
    checked: root.sourceEnabled("tailscale")
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.setSource("tailscale", !checked)
  }

  Toggle {
    width: parent.width
    label: "ZeroTier"
    description: {
      var zt = root.doctor ? root.doctor.zerotier : null
      if (!zt) return "Checking…"
      if (!zt.installed) return "Not installed"
      if (zt.localToken === "denied") return "Installed, but blussh can't read its local token"
      if (!zt.running) return "Installed, service not running"
      return zt.centralToken ? "Running · Central token set" : "Running · needs a Central token for member names"
    }
    checked: root.sourceEnabled("zerotier")
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.setSource("zerotier", !checked)
  }

  Column {
    visible: root.sourceEnabled("zerotier") && root.doctor !== null
    width: parent.width
    spacing: Style.space(8)
    readonly property var zt: root.doctor ? root.doctor.zerotier : ({})

    Button {
      visible: parent.zt.installed === false
      text: "Install ZeroTier"
      iconText: "󰏗"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.openTerminal("omarchy pkg add zerotier-one && sudo systemctl enable --now zerotier-one")
    }

    Button {
      visible: parent.zt.installed === true && parent.zt.running === false && parent.zt.localToken !== "denied"
      text: "Start ZeroTier service"
      iconText: "󰐊"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.openTerminal("sudo systemctl enable --now zerotier-one")
    }

    Button {
      visible: parent.zt.localToken === "denied"
      text: "Grant blussh access to ZeroTier"
      iconText: "󰌆"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.openTerminal("python3 " + root.script + " zerotier-authtoken")
    }

    Text {
      visible: parent.zt.installed === true
      width: parent.width
      text: "Central API token (my.zerotier.com → Account → API Access Tokens)"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    RowLayout {
      visible: parent.zt.installed === true
      width: parent.width
      spacing: Style.space(6)
      TextField {
        id: tokenField
        Layout.fillWidth: true
        password: true
        foreground: root.foreground
        placeholderText: parent.parent.zt.centralToken === true ? "Token saved — paste to replace" : "API token"
        onAccepted: root.saveToken()
      }
      Button {
        text: "Save"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !tokenProcess.running
        onClicked: root.saveToken()
      }
    }

    Text {
      visible: root.tokenStatus !== ""
      width: parent.width
      text: (root.tokenOk ? "✓ " : (tokenProcess.running ? "" : "✗ ")) + root.tokenStatus
      color: root.tokenOk || tokenProcess.running ? root.dim : root.panel.downColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  // ── Behavior ───────────────────────────────────────────────────────────

  PanelSeparator { foreground: root.foreground }
  PanelSectionHeader { text: "BEHAVIOR"; foreground: root.foreground; fontFamily: root.fontFamily }

  Toggle {
    width: parent.width
    label: "Notifications"
    description: "Notify when hosts go down or come back"
    checked: root.service.notifications
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.panel.saveSetting("notifications", !checked)
  }

  Toggle {
    width: parent.width
    label: "Hide hidden hosts"
    description: "Leave hosts you hid out of the list"
    checked: root.panel.hideDisabled
    foreground: root.foreground
    fontFamily: root.fontFamily
    onClicked: root.panel.saveSetting("hideDisabled", !checked)
  }

  Text {
    text: "Refresh every"
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Row {
    spacing: Style.space(6)
    Repeater {
      model: [{ label: "5s", value: 5 }, { label: "10s", value: 10 }, { label: "30s", value: 30 }, { label: "1m", value: 60 }, { label: "5m", value: 300 }]
      Button {
        required property var modelData
        text: modelData.label
        selected: root.service.refreshIntervalSec === modelData.value
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.panel.saveSetting("refreshIntervalSec", modelData.value)
      }
    }
  }

  // ── Processes ──────────────────────────────────────────────────────────

  Process {
    id: doctorProcess
    command: ["python3", root.service.scriptPath, "doctor", "--ssh-config", root.service.sshConfigPaths]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.doctor = JSON.parse(text) } catch (e) { root.doctor = null }
      }
    }
  }

  Process {
    id: pickProcess
    command: ["omarchy-file-select", "--title", "Add SSH config file"]
    stdout: StdioCollector {
      onStreamFinished: {
        var picked = String(text || "").trim().split("\n")[0]
        if (picked !== "") root.addPath(picked)
      }
    }
  }

  Process {
    id: tokenProcess
    property string token: ""
    command: ["python3", root.service.scriptPath, "zerotier-token", "--stdin"]
    stdinEnabled: true
    onStarted: {
      write(token)
      token = ""
      stdinEnabled = false  // closes stdin so the backend sees EOF
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.tokenOk = result.ok === true
          root.tokenStatus = String(result.message || "")
          if (root.tokenOk) {
            tokenField.text = ""
            root.refreshDoctor()
            root.service.refresh()
          }
        } catch (e) {
          root.tokenOk = false
          root.tokenStatus = "could not run the token check"
        }
      }
    }
    onExited: stdinEnabled = true
  }
}
