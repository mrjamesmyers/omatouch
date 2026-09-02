import QtQuick
import Quickshell
import Quickshell.Wayland

// The HUD's window: a click-through, FULL-SCREEN layer surface that is always
// mapped and usually invisible.
//
// Full-screen is not a style choice. The trackpad HUD is a small plate anchored
// near an edge because it draws a scale model; this one draws contacts at their
// true display coordinates, so the surface has to BE the display or the
// coordinates have nothing to mean.
//
// Always mapped, for the reason the trackpad overlay gives: creating the
// surface on first contact would cost a roundtrip and a first-frame compile at
// exactly the moment someone is looking at it, so the HUD would arrive a beat
// behind the finger. An opacity-0 surface costs nothing, so it stays up.
Variants {
  id: overlay

  // One decoded frame from touch-tap, pushed in by Service.qml.
  property var frame: ({ n: 0, click: false, f: [] })
  property bool light: false
  property int minContacts: 1
  property string style: "ripple"

  model: Quickshell.screens

  PanelWindow {
    id: win
    required property var modelData
    screen: modelData

    // A NAME NOTHING ELSE IS A PREFIX OF. Hyprland matches layer rules as
    // SUBSTRINGS, so a namespace that another rule's name begins with would
    // silently inherit that rule's blur and ignore_alpha. "omatouch-hud" is
    // not a prefix of, and does not begin with, any stock Omarchy layer name
    // or the omatrackpad one beside it.
    WlrLayershell.namespace: "omatouch-hud"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // All four edges: this surface is the whole screen.
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true

    color: "transparent"

    // NEVER TAKE A CLICK. This matters more here than for any other surface in
    // the shell, and more than it does for the trackpad HUD. A full-screen
    // overlay that accepted input on a TOUCHSCREEN would swallow every touch
    // the moment it mapped -- and it is mapped all the time. An empty Region
    // is fully transparent to input.
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    // Linger briefly after the last contact lifts, so a run of quick taps
    // reads as one continuous HUD rather than a strobe.
    property bool wanted: overlay.frame && overlay.frame.n >= overlay.minContacts
    property bool showing: false
    onWantedChanged: {
      if (wanted) { linger.stop(); showing = true }
      else linger.restart()
    }
    Timer {
      id: linger
      // Shorter than the trackpad's 420ms. A touch HUD sits over the thing you
      // just tapped, so it has to get out of the way faster than one that
      // lives in a corner.
      interval: 260
      onTriggered: win.showing = false
    }

    Hud {
      id: hud
      anchors.fill: parent
      frame: overlay.frame
      light: overlay.light
      style: overlay.style
      opacity: win.showing ? 1 : 0
      // Asymmetric: appear immediately, leave gently. A HUD that fades IN is a
      // HUD that is late -- and on a touchscreen the finger is already there.
      Behavior on opacity {
        NumberAnimation { duration: win.showing ? 60 : 200; easing.type: Easing.OutQuad }
      }
    }
  }
}
