import QtQuick

// A contact, drawn where the finger is.
//
// THIS IS NOT THE TRACKPAD HUD, AND THE DIFFERENCE IS THE WHOLE DESIGN.
//
// prezziej.trackpad draws a scale model of the pad, because a trackpad is not
// the screen: the only way to show where a finger is, is to draw a little
// picture of the surface and put a dot on it. A touchscreen inverts that. The
// finger is already resting on the pixel it is pointing at, so a scale model
// would be a picture of the screen, drawn on that screen, underneath the hand
// it is depicting -- redundant at best, and at worst it covers the thing you
// are trying to look at.
//
// So there is no plate here. Each contact is drawn at its own display
// coordinate, at full size, and the "HUD" is the whole screen.
Item {
  id: root

  // One decoded frame from touch-tap. x and y are 0..1 in display space.
  property var frame: ({ n: 0, click: false, f: [] })
  property bool light: false
  property string style: "ripple"      // ripple | dot | crosshair

  readonly property color ink: root.light ? "#101014" : "#f4f4f8"
  readonly property color glow: root.light ? "#3a6ff0" : "#66a3ff"

  readonly property var contacts: (frame && frame.f) ? frame.f : []

  Repeater {
    // KEYED BY NOTHING, REBUILT EVERY FRAME -- deliberately.
    //
    // The obvious optimisation is a DelegateModel keyed on the tracking id, so
    // a contact keeps its delegate and can animate between positions. It is
    // the wrong trade here: this HUD exists to show you the truth about a
    // panel, and an interpolating delegate would smooth over exactly the
    // dropped frames and coordinate jumps that a failing digitizer produces.
    // A dot that stutters is a dot that is telling you something.
    model: root.contacts

    delegate: Item {
      id: contact
      required property var modelData

      readonly property real px: (modelData.x !== undefined ? modelData.x : 0) * root.width
      readonly property real py: (modelData.y !== undefined ? modelData.y : 0) * root.height
      // Pressure is optional: plenty of panels report no ABS_MT_PRESSURE at
      // all. Fall back to a mid value rather than drawing nothing.
      readonly property real press: modelData.p !== undefined ? modelData.p : 0.5

      x: px
      y: py

      // Ripple: a filled core with an expanding ring, sized by pressure.
      Rectangle {
        visible: root.style === "ripple"
        anchors.centerIn: parent
        width: 26 + contact.press * 26
        height: width
        radius: width / 2
        color: root.glow
        opacity: 0.22
      }
      Rectangle {
        visible: root.style === "ripple"
        anchors.centerIn: parent
        width: 15 + contact.press * 12
        height: width
        radius: width / 2
        color: root.glow
        opacity: 0.85
      }
      Rectangle {
        visible: root.style === "ripple"
        anchors.centerIn: parent
        width: 46 + contact.press * 34
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 2
        border.color: root.glow
        opacity: 0.45
      }

      // Dot: the quietest option, for when the HUD is on all the time.
      Rectangle {
        visible: root.style === "dot"
        anchors.centerIn: parent
        width: 17
        height: width
        radius: width / 2
        color: root.glow
        border.width: 1.5
        border.color: root.ink
        opacity: 0.9
      }

      // Crosshair: full-width rules through the contact. The one to use when
      // you are checking whether a touch lands where you put it, because it
      // reads against screen content instead of floating on top of it.
      Rectangle {
        visible: root.style === "crosshair"
        y: -contact.py
        x: -1
        width: 2
        height: root.height
        color: root.glow
        opacity: 0.5
      }
      Rectangle {
        visible: root.style === "crosshair"
        x: -contact.px
        y: -1
        width: root.width
        height: 2
        color: root.glow
        opacity: 0.5
      }
      Rectangle {
        visible: root.style === "crosshair"
        anchors.centerIn: parent
        width: 11
        height: width
        radius: width / 2
        color: root.glow
      }

      // The tracking id, so two contacts can be told apart while they move --
      // the thing you need when checking whether a panel swaps its slots under
      // a two-finger gesture, which old digitizers genuinely do.
      Text {
        visible: root.style !== "dot" && contact.modelData.id !== undefined
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.verticalCenter
        anchors.topMargin: 34
        text: contact.modelData.id
        color: root.ink
        opacity: 0.65
        font.pixelSize: 12
        font.family: "monospace"
      }
    }
  }
}
