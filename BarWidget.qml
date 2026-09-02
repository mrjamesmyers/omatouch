import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar slot: a small screen glyph that fills in when the panel is live and
// hollows out when it is switched off, with the contacts currently down drawn
// inside it. Click to open the settings panel.
//
// It holds no state of its own. Presence, contact count and the on/off state
// all come off the service, because the service is the thing already holding
// the reader open -- a second copy of any of that here would drift the first
// time either changed.
BarWidget {
  id: root
  moduleName: "prezziej.touchscreen"

  readonly property var service: bar && bar.shell
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property bool ready: service !== null && service !== undefined
  readonly property bool present: ready && service.present === true
  // Derived through the guard, never dereferenced inline. A plugin reload nulls
  // `service` while bindings that read `present` are still queued, so
  // `root.service.model` inside an expression guarded on `present` throws
  // "Cannot read property 'model' of null" on every hot reload.
  readonly property string model: ready ? (service.model || "") : ""
  readonly property bool enabled: ready && service.value("enabled") === true
  readonly property bool active: ready && service.active === true
  readonly property bool lidClosed: ready && service.lidClosed === true
  readonly property int slots: ready ? service.slots : 0
  readonly property int contacts: ready ? service.contacts : 0
  readonly property bool permissionDenied: ready && service.permissionDenied === true
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // BarWidget does not derive its implicit size from children, so the button's
  // size has to be forwarded or the bar creates a zero-width, unclickable slot.
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  // VISIBLE WHEN DENIED, NOT JUST WHEN PRESENT. A permissions failure looks
  // exactly like absent hardware from here, and hiding the widget would leave
  // someone with a working touchscreen and no way to find out why the plugin
  // appears to do nothing. Show it, and let the tooltip explain.
  visible: present || permissionDenied

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color warn: bar ? bar.urgent : Color.urgent

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.hostWidget = root
    target.service = root.service
  }

  onBarChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      // Injected twice on purpose: `bar` and `service` can both resolve after
      // the Loader completes, and a panel with a null bar renders with the
      // fallback palette instead of the theme's.
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    // A LITERAL, not `root.moduleName` -- see the note in Service.qml. As a
    // binding this re-evaluates on every hot reload and segfaults the shell.
    target: "prezziej.touchscreen.bar"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    bar: root.bar
    active: root.opened

    tooltipText: {
      if (root.permissionDenied)
        return "Touchscreen unreadable — add yourself to the 'input' group and log back in"
      if (!root.present) return "No touchscreen"
      var bits = [root.model]
      bits.push(root.slots > 0 ? root.slots + "-point" : "multitouch")
      if (!root.enabled) bits.push("off")
      else if (root.lidClosed) bits.push("lid shut")
      else if (root.contacts > 0) bits.push(root.contacts + " down")
      return bits.join("  ·  ")
    }

    // This button's content is drawn, not typed, and WidgetButton defaults
    // hasVisualContent to `text !== ""` -- leave it false and the bar treats
    // the slot as empty and gives it no room.
    hasVisualContent: true
    fixedWidth: content.implicitWidth + scaledHorizontalMargin * 2

    // WidgetButton emits pressed(button) and registers itself as one of the
    // bar's click targets; it has no `clicked`. The bar dispatches, which is
    // how tooltips and popout switching stay coordinated across widgets.
    onPressed: function(code) { root.toggle() }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: 5

      // A screen, at a screen's proportions -- deliberately NOT the trackpad
      // plugin's plate. 16:9 reads as a display; the trackpad's 162:115 reads
      // as a pad. Someone running both plugins should be able to tell the two
      // widgets apart at a glance without reading either.
      Rectangle {
        id: glass
        anchors.verticalCenter: parent.verticalCenter
        height: Math.max(9, Math.round(root.barSize * 0.30))
        width: Math.round(height * (16 / 9))
        radius: Math.max(1, Math.round(height * 0.14))
        color: "transparent"
        border.width: 1.3
        border.color: root.permissionDenied ? root.warn : root.fg

        // Off reads as dimmed and dashed-looking rather than absent: the panel
        // is still fitted, it is just not listening.
        opacity: !root.active ? 0.34 : (root.contacts > 0 ? 1 : 0.78)
        Behavior on opacity { NumberAnimation { duration: 140 } }

        // Contacts drawn INSIDE the glyph at their real relative positions, so
        // the bar shows roughly where on the panel a touch landed even with the
        // HUD switched off. The trackpad widget shows a row of dots because a
        // pad has no meaningful "where" at bar size; a screen does.
        Repeater {
          model: root.ready && root.service.frame && root.service.frame.f
            ? root.service.frame.f : []
          delegate: Rectangle {
            required property var modelData
            width: Math.max(1.6, Math.round(glass.height * 0.19))
            height: width
            radius: width / 2
            color: root.fg
            x: Math.round((modelData.x !== undefined ? modelData.x : 0.5)
                          * glass.width) - width / 2
            y: Math.round((modelData.y !== undefined ? modelData.y : 0.5)
                          * glass.height) - height / 2
          }
        }

        // A slash across the glyph when the panel is switched off. Opacity
        // alone is too subtle in a busy bar to answer "is my touchscreen on?"
        Rectangle {
          visible: root.present && !root.active
          anchors.centerIn: parent
          width: Math.round(glass.width * 1.16)
          height: 1.3
          color: root.fg
          rotation: -28
          antialiasing: true
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.permissionDenied
        text: "!"
        color: root.warn
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.weight: Font.Bold
      }
    }
  }
}
