import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "blusa.blussh"
  ipcTarget: "blusa.blussh"
  manageIpc: false

  property int cursorIndex: 0
  property bool cursorActive: false
  property bool actionMenuOpen: false
  // Only keyboard moves scroll; a hover must never yank the list around
  property bool scrollOnCursor: false
  property double now: Date.now()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool hideDisabled: settings.hideDisabled !== false
  property string view: "hosts"   // hosts | settings
  readonly property int hiddenCount: {
    var n = 0
    for (var i = 0; i < blussh.hosts.length; i++)
      if (!blussh.hosts[i].enabled && !blussh.hosts[i].placeholder) n++
    return n
  }

  // Writes one key into this widget's bar entry in shell.json (hot-reloads
  // into `settings`), the same store the bar settings panel edits.
  function saveSetting(key, value) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var entry = { id: moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    bar.shell.updateEntryInline(moduleName, entry)
  }

  function toggleHidden(host) {
    if (!host || host.placeholder) return
    blussh.setEnabled(host, !host.enabled)
  }

  // Hosts grouped by source, in backend order, plus a flat list of the
  // selectable rows so j/k can walk across group boundaries.
  readonly property var groups: {
    var result = []
    var byTitle = {}
    var nav = 0
    for (var i = 0; i < blussh.hosts.length; i++) {
      var host = blussh.hosts[i]
      if (hideDisabled && !host.enabled && !host.placeholder) continue
      var group = byTitle[host.group]
      if (!group) {
        group = { title: host.group, online: 0, total: 0, rows: [] }
        byTitle[host.group] = group
        result.push(group)
      }
      if (host.enabled && !host.placeholder) {
        group.total++
        if (host.online) group.online++
      }
      group.rows.push({ host: host, navIndex: host.placeholder ? -1 : nav++ })
    }
    return result
  }
  readonly property var navHosts: {
    var list = []
    for (var g = 0; g < groups.length; g++)
      for (var r = 0; r < groups[g].rows.length; r++)
        if (groups[g].rows[r].navIndex >= 0) list.push(groups[g].rows[r].host)
    return list
  }

  readonly property string statusTitle: {
    if (!blussh.loaded) return "blussh"
    if (blussh.total === 0) return "No hosts monitored"
    if (blussh.status === "all-online") return "All " + blussh.total + " hosts online"
    if (blussh.status === "all-offline") return "All hosts offline"
    return blussh.online + " of " + blussh.total + " hosts online"
  }
  readonly property string statusMeta: {
    if (blussh.busy && !blussh.loaded) return "Checking hosts…"
    if (!blussh.loaded) return blussh.lastError || "Waiting for first check"
    var seconds = Math.max(0, Math.round((now - blussh.updated * 1000) / 1000))
    var ago = seconds < 5 ? "just now" : (seconds < 90 ? seconds + "s ago" : Math.round(seconds / 60) + "m ago")
    return (blussh.busy ? "Checking… · " : "") + "Updated " + ago
  }

  // Status palette: the theme's green/orange/red when it has real hues, the
  // classic traffic-light colors when the theme is grayscale — the dot is the
  // whole point of the widget, so it must never blend into the bar.
  property var themePalette: ({})
  function paletteColor(name, fallback) {
    var value = themePalette[name]
    if (!value) return fallback
    var c = Qt.color(value)
    return c.hsvSaturation >= 0.3 ? c : fallback
  }
  readonly property color upColor: paletteColor("green", "#30d158")
  readonly property color partialColor: paletteColor("orange", paletteColor("yellow", "#ff9f0a"))
  readonly property color downColor: paletteColor("red", "#ff453a")

  function statusColor(status) {
    if (status === "all-online") return upColor
    if (status === "some-online") return partialColor
    if (status === "all-offline") return downColor
    return dim
  }

  function loadPalette(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
      if (m) next[m[1]] = m[2]
    }
    themePalette = next
  }

  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: root.loadPalette(text())
    onLoadFailed: root.loadPalette("")
  }

  // Theme switches arrive over shell IPC, not as a file change we can watch
  Connections {
    target: Color
    function onForegroundChanged() { themeColors.reload() }
    function onBackgroundChanged() { themeColors.reload() }
  }

  function selectedHost() {
    if (navHosts.length === 0) return null
    return navHosts[Math.max(0, Math.min(cursorIndex, navHosts.length - 1))]
  }

  function moveCursor(dy) {
    if (!cursorActive) { cursorActive = true; return }
    if (navHosts.length === 0) return
    scrollOnCursor = true
    cursorIndex = Math.max(0, Math.min(navHosts.length - 1, cursorIndex + dy))
  }

  function setCursor(index) {
    scrollOnCursor = false
    cursorActive = true
    cursorIndex = index
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function openActionMenu(host) {
    if (!host || host.placeholder) return
    actionMenu.host = host
    actionMenu.index = 0
    actionMenu.open()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    view = "hosts"
    cursorActive = false
    now = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    blussh.refreshIfStale()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onNavHostsChanged: if (cursorIndex >= navHosts.length) cursorIndex = Math.max(0, navHosts.length - 1)

  Service {
    id: blussh
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { blussh.refresh(); return "ok" }
    function settings(): void { root.open(); root.view = "settings" }
    function status(): string { return blussh.status + " " + blussh.online + "/" + blussh.total }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  // "HOSTNAME ●" like the macOS menu bar item. The label is kept invisible and
  // only sizes the button; the row on top paints the dot in its own color.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property string hostLabel: blussh.hostname || "blussh"
    text: vertical ? "●" : hostLabel + " ●"
    labelVisible: false
    hasVisualContent: true
    tooltipText: blussh.loaded ? blussh.online + "/" + blussh.total + " hosts online" : "blussh"

    Row {
      anchors.centerIn: parent
      spacing: 0
      Text {
        visible: !button.vertical
        text: button.hostLabel + " "
        color: root.barForeground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: "●"
        color: root.statusColor(blussh.status)
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 160 } }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) blussh.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.actionMenuOpen
      onMoveRequested: function(dx, dy) {
        if (root.view !== "hosts") return
        if (dx > 0 && root.cursorActive) root.openActionMenu(root.selectedHost())
        else if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.view === "hosts" && root.cursorActive) blussh.copySshCommand(root.selectedHost())
      onCloseRequested: {
        if (root.view !== "hosts") root.view = "hosts"
        else root.close()
      }
      onDeleteRequested: if (root.view === "hosts" && root.cursorActive) root.toggleHidden(root.selectedHost())
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === ",") { root.view = root.view === "hosts" ? "settings" : "hosts"; return }
        if (root.view !== "hosts") return
        var host = root.cursorActive ? root.selectedHost() : null
        if (t === "r" || t === "R") blussh.refresh()
        else if (t === "." ) root.saveSetting("hideDisabled", !root.hideDisabled)
        else if (!host) return
        else if (t === "c" || t === "C") blussh.copySshCommand(host)
        else if (t === "o" || t === "O") { blussh.openSsh(host); root.close() }
        else if (t === "m" || t === "M") blussh.setEnabled(host, !host.enabled)
        else if (t === "s" || t === "S") blussh.setIsSSHServer(host, !host.isSSHServer)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.view === "settings" ? "Settings" : root.statusTitle
            meta: root.view === "settings" ? "blussh · esc to go back" : root.statusMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              BlusshIcon {
                iconSize: Style.font.display
                fontFamily: root.fontFamily
                color: blussh.loaded ? root.foreground : root.dim
                badgeColor: root.statusColor(blussh.status)
                badge: blussh.loaded
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                PanelActionButton {
                  visible: root.view === "hosts" && root.hiddenCount > 0
                  iconText: root.hideDisabled ? "󰈉" : "󰈈"
                  tooltipText: (root.hideDisabled ? "Show " : "Hide ") + root.hiddenCount + " hidden host" + (root.hiddenCount === 1 ? "" : "s") + " (.)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.saveSetting("hideDisabled", !root.hideDisabled)
                }
                PanelActionButton {
                  visible: root.view === "hosts"
                  iconText: "󰑐"
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !blussh.busy
                  opacity: blussh.busy ? 0.45 : 1.0
                  onClicked: blussh.refresh()
                }
                PanelActionButton {
                  iconText: root.view === "settings" ? "󰁍" : "󰒓"
                  tooltipText: root.view === "settings" ? "Back to hosts (esc)" : "Settings (,)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.view = root.view === "settings" ? "hosts" : "settings"
                }
              }
            }
          }

          Settings {
            visible: root.view === "settings"
            width: parent.width
            panel: root
            service: blussh
          }

          Text {
            textFormat: Text.PlainText
            visible: root.view === "hosts" && (blussh.actionStatus !== "" || blussh.lastError !== "")
            width: parent.width
            text: blussh.actionStatus !== "" ? blussh.actionStatus : blussh.lastError
            color: blussh.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            // Sources that aren't installed are explained in settings instead
            model: root.view === "hosts" ? blussh.errors.filter(function(e) { return !e.missing }) : []
            Text {
              required property var modelData
              textFormat: Text.PlainText
              width: column.width
              text: String(modelData.source) + ": " + String(modelData.message)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            visible: root.view === "hosts" && blussh.loaded && root.groups.length === 0
            width: parent.width
            text: "No hosts found. Add ssh config files or set up Tailscale / ZeroTier in settings (,)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.view === "hosts" ? root.groups : []

            Column {
              id: groupColumn
              required property var modelData
              width: column.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.foreground }

              RowLayout {
                width: parent.width
                PanelSectionHeader {
                  Layout.fillWidth: true
                  text: String(groupColumn.modelData.title).toUpperCase()
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  elide: Text.ElideRight
                }
                PanelSectionHeader {
                  visible: groupColumn.modelData.total > 0
                  text: groupColumn.modelData.online + "/" + groupColumn.modelData.total
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
              }

              Repeater {
                model: groupColumn.modelData.rows
                HostRow {
                  required property var modelData
                  width: groupColumn.width
                  host: modelData.host
                  navIndex: modelData.navIndex
                }
              }
            }
          }
        }
      }

      Popup {
        id: actionMenu
        property var host: null
        property int index: 0
        readonly property var options: {
          if (!host) return []
          var list = [{ kind: "copy", label: "Copy " + host.sshCommand, glyph: "󰆏" }]
          if (host.isSSHServer) list.push({ kind: "open", label: "Open ssh session", glyph: "󰆍" })
          list.push({ kind: "monitor", label: host.enabled ? "Hide host (stops monitoring)" : "Show and monitor again", glyph: host.enabled ? "󰈉" : "󰈈" })
          if (host.netOnline !== null && host.netOnline !== undefined)
            list.push({ kind: "ssh", label: host.isSSHServer ? "Don't check SSH port" : "Check SSH port", glyph: "󰣀" })
          return list
        }

        anchors.centerIn: parent
        width: Style.space(300)
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        function choose(kind) {
          var h = host
          close()
          if (kind === "copy") blussh.copySshCommand(h)
          else if (kind === "open") { blussh.openSsh(h); root.close() }
          else if (kind === "monitor") blussh.setEnabled(h, !h.enabled)
          else if (kind === "ssh") blussh.setIsSSHServer(h, !h.isSSHServer)
        }

        onOpenedChanged: {
          root.actionMenuOpen = opened
          if (opened) Qt.callLater(function() { actionMenuContent.forceActiveFocus() })
          else if (root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }

        background: BorderSurface {
          color: Color.background
          borderSpec: Border.flat(root.dim, 1)
          radius: Style.cornerRadius
        }

        contentItem: Column {
          id: actionMenuContent
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left || event.text === "h") {
              actionMenu.close()
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              actionMenu.index = Math.min(actionMenu.options.length - 1, actionMenu.index + 1)
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              actionMenu.index = Math.max(0, actionMenu.index - 1)
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              if (actionMenu.options.length > 0) actionMenu.choose(actionMenu.options[actionMenu.index].kind)
            } else {
              return
            }
            event.accepted = true
          }

          Repeater {
            model: actionMenu.options
            CursorSurface {
              id: choice
              required property var modelData
              required property int index
              width: actionMenuContent.width > 0 ? actionMenuContent.width : actionMenu.width
              implicitHeight: Style.space(44)
              radius: 0
              foreground: root.foreground
              hasCursor: actionMenu.index === index

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: actionMenu.index = choice.index
                onClicked: actionMenu.choose(choice.modelData.kind)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Text {
                  text: choice.modelData.glyph
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  Layout.preferredWidth: Style.space(20)
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: choice.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }
  }

  component HostRow: CursorSurface {
    id: hostRow
    property var host: null
    property int navIndex: -1
    readonly property bool placeholder: host && host.placeholder === true
    readonly property bool monitored: host && host.enabled === true
    readonly property string detail: {
      if (!host || placeholder) return ""
      var parts = host.isSSHServer ? [host.sshCommand] : [host.address]
      if (host.isSSHServer && host.sshAlias && host.address !== host.sshAlias) parts.push(host.address)
      if (!monitored) parts.push("hidden")
      return parts.join(" · ")
    }

    hasCursor: root.cursorActive && navIndex >= 0 && root.cursorIndex === navIndex
    foreground: root.foreground
    implicitHeight: hostContent.implicitHeight + Style.spacing.rowPaddingX

    onHasCursorChanged: if (hasCursor && root.scrollOnCursor) root.scrollItemIntoView(hostRow)

    MouseArea {
      anchors.fill: parent
      enabled: !hostRow.placeholder
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(hostRow.navIndex)
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.openActionMenu(hostRow.host)
        else blussh.copySshCommand(hostRow.host)
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      // Status dot: green when online, red when down, hollow when unmonitored
      Rectangle {
        visible: !hostRow.placeholder
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(9)
        implicitHeight: Style.space(9)
        radius: width / 2
        color: !hostRow.monitored ? "transparent" : (hostRow.host.online ? root.upColor : root.downColor)
        border.width: hostRow.monitored ? 0 : 1
        border.color: root.dim
      }

      ColumnLayout {
        id: hostContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: hostRow.host ? hostRow.host.name : ""
          color: hostRow.placeholder || !hostRow.monitored ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: hostRow.placeholder ? Style.font.bodySmall : Style.font.body
          wrapMode: hostRow.placeholder ? Text.WordWrap : Text.NoWrap
          elide: hostRow.placeholder ? Text.ElideNone : Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          Layout.fillWidth: true
          text: hostRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: hostRow.placeholder && String(hostRow.host.name).indexOf("token") !== -1
        iconText: "󰌆"
        tooltipText: "Set ZeroTier Central token"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: { blussh.setZeroTierToken(); root.close() }
      }

      PanelActionButton {
        visible: !hostRow.placeholder && hostRow.host.isSSHServer
        iconText: "󰆍"
        tooltipText: "Open ssh session (o)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: { blussh.openSsh(hostRow.host); root.close() }
      }

      PanelActionButton {
        visible: !hostRow.placeholder
        iconText: "󰇘"
        tooltipText: "More actions (l)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.openActionMenu(hostRow.host)
      }
    }
  }
}
