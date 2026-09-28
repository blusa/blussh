import QtQuick
import qs.Commons
import qs.Ui

// Server glyph tinted by aggregate status, with an urgent badge when only
// some hosts are down (all down tints the glyph itself).
Item {
  id: root

  property real iconSize: Style.font.icon
  property string fontFamily: Style.font.family
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool badge: false

  implicitWidth: glyph.implicitWidth
  implicitHeight: glyph.implicitHeight
  width: implicitWidth
  height: implicitHeight

  Text {
    id: glyph
    anchors.centerIn: parent
    text: "󰒋"
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.iconSize
  }

  BorderSurface {
    visible: root.badge
    width: Math.max(5, root.iconSize * 0.38)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.15
    borderSpec: Border.flat(Color.popups.background, 1)
  }
}
