import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// The touchscreen settings panel.
//
// Built out of the shell's OWN component kit -- Panel, KeyboardPanel,
// PanelHero, PanelSectionHeader, ToggleSwitch, ButtonGroup -- and not out of
// hand-rolled rectangles, for the same reason the trackpad panel is: it
// inherits the bar's colours, fonts, corner radius, border spec and focus
// behaviour, so it matches the audio and bluetooth panels exactly and keeps
// matching them when the theme changes.
//
// Two tabs, not four. The trackpad panel mirrors macOS's System Settings >
// Trackpad because there is a well-known layout to mirror. There is no such
// reference for a touchscreen, and padding this out with tabs that hold one
// row each would be worse than honest: Panel is what the hardware does, Test
// is how you find out whether it still does it.
Panel {
  id: root
  moduleName: "prezziej.touchscreen"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: Color.accent

  readonly property bool haveService: service !== null && service !== undefined
  readonly property bool present: haveService && service.present === true

  // GUARDED ACCESSORS, one per fact the panel shows. `present` is a cached
  // binding, and on a plugin hot-reload `service` is nulled while bindings
  // derived from it are still queued to re-evaluate. Anything written as
  // `root.present ? root.service.x : y` throws "Cannot read property 'x' of
  // null" on every reload; reading through `haveService` at the point of
  // dereference cannot.
  readonly property string svcModel: haveService ? (service.model || "") : ""
  readonly property string svcDevice: haveService ? (service.deviceName || "") : ""
  readonly property int svcSlots: haveService ? service.slots : 0
  readonly property bool svcSemiMt: haveService && service.semiMt === true
  readonly property bool svcDenied: haveService && service.permissionDenied === true
  readonly property bool svcActive: haveService && service.active === true
  readonly property bool svcLidClosed: haveService && service.lidClosed === true
  readonly property var svcHyprNames: haveService && service.hyprNames ? service.hyprNames : []
  readonly property string svcOrientation: haveService ? (service.orientation || "normal") : "normal"
  readonly property bool svcSure: haveService && service.orientationSure === true
  readonly property bool svcFlat: haveService && service.flat === true
  readonly property string svcKeyboard: haveService ? (service.keyboardName || "") : ""
  readonly property string svcTouchpad: haveService ? (service.touchpadName || "") : ""
  readonly property bool svcClamshell: haveService && service.clamshell === true
  readonly property string svcLidPolicy: haveService ? (service.lidPolicy || "") : ""
  readonly property var svcFrame: haveService && service.frame
    ? service.frame : ({ n: 0, click: false, f: [] })

  function val(key, fallback) {
    if (!haveService) return fallback
    var v = service.value(key)
    return (v === undefined || v === null) ? fallback : v
  }

  function put(key, value) {
    if (!haveService) return
    var patch = {}
    patch[key] = value
    service.set(patch)
  }

  function open() { controller.show() }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  property string tab: "panel"
  readonly property var tabOptions: [
    { value: "panel", label: "Panel" },
    { value: "test",  label: "Test" }
  ]

  // ---- reusable rows -------------------------------------------------------
  component SwitchRow: RowLayout {
    id: sw
    property string label: ""
    property string description: ""
    property bool checked: false
    signal toggled(bool value)

    Layout.fillWidth: true
    spacing: Style.space(10)

    ColumnLayout {
      Layout.fillWidth: true
      spacing: 1
      Text {
        Layout.fillWidth: true
        text: sw.label
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        wrapMode: Text.WordWrap
      }
      Text {
        Layout.fillWidth: true
        visible: sw.description !== ""
        text: sw.description
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      Layout.alignment: Qt.AlignVCenter
      checked: sw.checked
      foreground: root.foreground
      accent: root.accent
      onToggled: sw.toggled(!sw.checked)
    }
  }

  component ChoiceRow: ColumnLayout {
    id: ch
    property string label: ""
    property string description: ""
    property var options: []
    property string value: ""
    signal changed(string value)

    Layout.fillWidth: true
    spacing: Style.space(4)

    Text {
      Layout.fillWidth: true
      text: ch.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
    }
    Text {
      Layout.fillWidth: true
      visible: ch.description !== ""
      text: ch.description
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
    ButtonGroup {
      Layout.fillWidth: true
      options: ch.options
      value: ch.value
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      onChanged: value => ch.changed(value)
    }
  }

  // ---- the popup -----------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        ColumnLayout {
          id: content
          width: parent.width
          spacing: Style.space(12)

          // NOT PanelHero, and the reason is a 14px gap.
          //
          // PanelHero anchors its labels to `iconLoader.right` plus
          // Style.space(14). With no iconComponent that loader is zero-width
          // at the left edge, so the margin survives as a pure indent -- the
          // title and the contacts line sat 14px right of the tab buttons and
          // every section below them. The shell owns that component and an
          // Omarchy update would take any fix to it back, so the header lives
          // here instead. Same typography, aligned to the same left edge as
          // the rest of the panel.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              visible: text !== ""
              text: heroFacts.title
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              visible: text !== ""
              text: heroFacts.meta.toUpperCase()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          QtObject {
            id: heroFacts
            property string title: {
              if (root.svcDenied) return "Touchscreen unreadable"
              return root.present ? (root.svcModel || "Touchscreen") : "No touchscreen"
            }
            property string meta: {
              // THE PERMISSIONS CASE GETS THE FIX, NOT A DIAGNOSIS. "Permission
              // denied" is true and useless; the two things someone has to do
              // are a group and a re-login, so say both.
              if (root.svcDenied)
                return "Add yourself to the 'input' group and log back in:  sudo usermod -aG input $USER"
              if (!root.present) return "No direct-touch device found in /dev/input"
              var parts = []
              if (root.svcSlots > 0) parts.push(root.svcSlots + " simultaneous contacts")
              if (root.svcSemiMt) parts.push("semi-MT (bounding box only)")
              if (!root.val("enabled", true)) parts.push("switched off")
              else if (root.svcLidClosed) parts.push("lid shut")
              return parts.join("  ·  ")
            }
          }

          ButtonGroup {
            Layout.fillWidth: true
            visible: root.present
            options: root.tabOptions
            value: root.tab
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onChanged: value => root.tab = value
          }

          // ---- Panel tab ---------------------------------------------------
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.present && root.tab === "panel"
            spacing: Style.space(10)

            SwitchRow {
              label: "Touchscreen"
              description: "Turn the panel off entirely."
              checked: root.val("enabled", true)
              onToggled: value => root.put("enabled", value)
            }

            SwitchRow {
              label: "Off when the lid is shut"
              description: "A folded convertible presses its own screen against the base, which reads as a stream of phantom touches."
              checked: root.val("disableWhenLidClosed", true)
              onToggled: value => root.put("disableWhenLidClosed", value)
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "POSTURE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SwitchRow {
              label: "Auto-rotate display"
              description: "Follow the accelerometer, rotating the screen and the digitizer together. Currently reading: "
                           + (root.svcFlat ? "flat (no rotation)"
                              : root.svcOrientation + (root.svcSure ? "" : " — unsure"))
              checked: root.val("autoRotate", true)
              onToggled: value => root.put("autoRotate", value)
            }

            SwitchRow {
              label: "Tablet mode"
              description: "Turns off the keyboard and touchpad. Folded back they face whatever the machine is resting on — and this Yoga reports no tablet switch, so nothing else does this for you."
              checked: root.val("tabletMode", false)
              onToggled: value => root.put("tabletMode", value)
            }

            SwitchRow {
              label: "Keep running with the lid shut"
              description: root.svcClamshell
                ? "Closing the lid will not suspend. Note it will not sleep on battery either — right for a car, wrong for a bag."
                : "Right now closing the lid suspends the machine, which stops anything logging. Turning this on asks for your password."
              checked: root.svcClamshell
              onToggled: value => { if (root.haveService) root.service.setClamshell(value) }
            }

            SwitchRow {
              label: "Enter tablet mode automatically"
              description: "A guess, not a reading. There is no tablet switch on this machine, so posture is inferred from orientation — and a laptop flat on a desk looks exactly like a tablet flat on a desk."
              checked: root.val("autoTabletMode", false)
              onToggled: value => root.put("autoTabletMode", value)
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "ORIENTATION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ChoiceRow {
              label: "Rotation"
              description: "If touches land at 90 degrees to your finger, the digitizer is mounted at a different rotation from the display. This corrects it."
              options: [
                { value: "0", label: "Normal" },
                { value: "1", label: "90" },
                { value: "2", label: "180" },
                { value: "3", label: "270" }
              ]
              value: String(root.val("transform", 0))
              onChanged: value => root.put("transform", parseInt(value, 10))
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "HUD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            SwitchRow {
              label: "Contact HUD"
              description: "Draw each contact where it actually is on the glass."
              checked: root.val("hud", true)
              onToggled: value => root.put("hud", value)
            }

            ChoiceRow {
              label: "Style"
              description: "Crosshair reads against screen content; dot is the quietest."
              options: [
                { value: "ripple",    label: "Ripple" },
                { value: "dot",       label: "Dot" },
                { value: "crosshair", label: "Crosshair" }
              ]
              value: String(root.val("hudStyle", "ripple"))
              onChanged: value => root.put("hudStyle", value)
              enabled: root.val("hud", true)
              opacity: enabled ? 1 : 0.4
            }
          }

          // ---- Test tab ----------------------------------------------------
          //
          // The reason this plugin has a Test tab and the trackpad plugin does
          // not: this machine's panel is from 2017, and the useful question is
          // not "how do I configure it" but "does all of it still work". A live
          // readout answers that in a way a settings list cannot.
          ColumnLayout {
            Layout.fillWidth: true
            visible: root.present && root.tab === "test"
            spacing: Style.space(10)

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "LIVE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              Layout.fillWidth: true
              text: root.svcFrame.n > 0
                ? root.svcFrame.n + " contact" + (root.svcFrame.n === 1 ? "" : "s") + " down"
                : "Touch the screen to see contacts here"
              color: root.svcFrame.n > 0 ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
            }

            // Coordinates, monospaced, one line per contact. This is the bit
            // that finds a dead patch: drag a finger across the panel and watch
            // for the numbers freezing or jumping.
            Repeater {
              model: root.svcFrame.f ? root.svcFrame.f : []
              delegate: Text {
                required property var modelData
                Layout.fillWidth: true
                text: "  id " + (modelData.id !== undefined ? modelData.id : "?")
                      + "   x " + Number(modelData.x !== undefined ? modelData.x : 0).toFixed(3)
                      + "   y " + Number(modelData.y !== undefined ? modelData.y : 0).toFixed(3)
                      + (modelData.p !== undefined
                         ? "   p " + Number(modelData.p).toFixed(2) : "")
                color: root.foreground
                font.family: "monospace"
                font.pixelSize: Style.font.caption
              }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "DEVICE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              Layout.fillWidth: true
              visible: root.svcKeyboard !== "" || root.svcTouchpad !== ""
              text: "Tablet mode would disable:\n  " + (root.svcKeyboard || "(no keyboard found)")
                    + "\n  " + (root.svcTouchpad || "(no touchpad found)")
              color: root.dim
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              Layout.fillWidth: true
              text: (root.svcDevice || "unknown")
                    + "\nHyprland: " + (root.svcHyprNames.length
                        ? root.svcHyprNames.join(", ")
                        : "not matched — settings will not apply")
              color: root.dim
              font.family: "monospace"
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- not present -------------------------------------------------
          Text {
            Layout.fillWidth: true
            visible: !root.present
            text: root.svcDenied
              ? "The panel is almost certainly fine — this is a permissions problem, not a hardware one. Group changes only take effect on a fresh login, so a new terminal is not enough."
              : "Nothing in /dev/input reports INPUT_PROP_DIRECT. A trackpad does not count; use the Trackpad plugin for that."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
