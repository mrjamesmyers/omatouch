import QtQuick
import Quickshell
import Quickshell.Io

// The touchscreen plugin's headless half: owns the reader, the generated
// Hyprland config, the settings file, and the IPC the bar panel and the CLI
// both use.
//
// Everything expensive is conditional on a touchscreen actually being present.
// Most machines have none, and a plugin that costs them anything for hardware
// they do not own has no business shipping -- so with no panel attached this is
// a 10-second poll and nothing else.
Scope {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/prezziej.touchscreen"
  readonly property string stateDir: home + "/.local/state/omarchy"
  readonly property string togglesFile: stateDir + "/toggles/hypr/touchscreen.lua"
  readonly property string settingsFile: stateDir + "/omatouch.json"

  // ---- settings ------------------------------------------------------------
  readonly property var defaults: ({
    enabled: true,
    hud: true,
    hudMinContacts: 1,
    hudStyle: "ripple",              // ripple | dot | crosshair
    transform: 0,                    // 0..7, Hyprland's transform enum
    output: "",                      // empty: let Hyprland decide
    device: "",                      // empty: prefer the built-in panel
    disableWhenLidClosed: true,

    // Tablet posture
    autoRotate: true,
    tabletMode: false,
    autoTabletMode: false,           // opt-in: see the note on inference below
    tabletDisablesKeyboard: true,
    tabletDisablesTouchpad: true
  })

  property var settings: ({})
  Component.onCompleted: root.settings = root.cloneDefaults()

  function cloneDefaults() {
    var out = {}
    for (var k in root.defaults) out[k] = root.defaults[k]
    return out
  }

  function value(key) {
    var v = root.settings ? root.settings[key] : undefined
    return (v === undefined || v === null) ? root.defaults[key] : v
  }

  // Written through a FileView with atomicWrites, so a shell that dies
  // mid-write leaves the previous settings intact rather than a truncated file.
  FileView {
    id: settingsView
    path: root.settingsFile
    printErrors: false
    atomicWrites: true
    onLoaded: root.adoptSettings(text())
  }

  function adoptSettings(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      // A corrupt settings file must not take the plugin down with it. Keep the
      // defaults and carry on; the next save rewrites it cleanly.
      return
    }
    if (!parsed || typeof parsed !== "object") return
    var merged = root.cloneDefaults()
    for (var k in parsed) {
      if (k in merged) merged[k] = parsed[k]
    }
    root.settings = merged
    root.applyConfig()
  }

  function saveSettings() {
    settingsView.setText(JSON.stringify(root.settings, null, 2) + "\n")
  }

  function setValue(key, v) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = v
    root.settings = next
    root.saveSettings()
    root.applyConfig()
  }

  // Patch form, which is what the panel calls. Batched rather than one
  // setValue() per key: each call writes the settings file and reloads
  // Hyprland, so a row that changes two keys would otherwise reload twice.
  function set(patch) {
    if (!patch) return
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    for (var p in patch) next[p] = patch[p]
    root.settings = next
    root.saveSettings()
    root.applyConfig()
  }

  function resetSettings() {
    root.settings = root.cloneDefaults()
    root.saveSettings()
    root.applyConfig()
  }

  // ---- live state ----------------------------------------------------------
  property bool present: false
  property string model: ""
  property string deviceName: ""
  property int slots: 0
  property bool semiMt: false
  property var interfaces: []
  property var devices: []
  property var hyprNames: []
  property string lastError: ""
  // Distinguished from "no touchscreen" on purpose: the two look identical
  // from the outside and have completely different fixes.
  property bool permissionDenied: false

  property var frame: ({ n: 0, click: false, f: [] })
  readonly property int contacts: frame && frame.n ? frame.n : 0

  property bool lidClosed: false

  // ---- orientation ---------------------------------------------------------
  //
  // ORIENTATION IS MEASURED; POSTURE IS INFERRED. This machine reports no
  // SW_TABLET_MODE -- its only switch bit is SW_LID -- so nothing can tell us
  // the screen has been folded back. What the accelerometer can tell us is
  // which edge is down, and that is enough to rotate correctly.
  //
  // It is NOT enough to decide the thing is a tablet: a laptop lying open on a
  // desk and a tablet lying on a desk give the same reading. That is why
  // autoTabletMode defaults off and the manual toggle is the primary control.
  property string orientation: "normal"
  property int autoTransform: 0
  property bool orientationSure: false
  property bool flat: false

  // Effective rotation: the sensor when auto-rotate is on and confident,
  // otherwise whatever was set by hand.
  readonly property int effectiveTransform: {
    if (root.value("autoRotate") && root.orientationSure) return root.autoTransform
    return Number(root.value("transform")) | 0
  }

  readonly property bool tabletMode: root.value("tabletMode") === true

  // Hyprland device names for the keyboard and touchpad, discovered rather
  // than hardcoded -- they differ between machines and this plugin should not
  // assume a PS/2 pad.
  property string keyboardName: ""
  property string touchpadName: ""
  property string monitorName: ""
  property real monitorScale: 1

  // ---- clamshell -----------------------------------------------------------
  //
  // Not a Hyprland setting like everything else here: this is
  // systemd-logind policy in /etc, readable by anyone over D-Bus and writable
  // only as root. So the panel always shows the truth and offers the toggle
  // through pkexec, rather than pretending the plugin owns it.
  property bool clamshell: false
  property string lidPolicy: ""
  property bool clamshellManaged: false

  Process {
    id: clam
    command: [root.pluginDir + "/scripts/clamshell", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var o = JSON.parse(text)
          root.clamshell = o.clamshell === true
          root.lidPolicy = String(o.on_battery || "")
          root.clamshellManaged = o.managed === true
        } catch (e) { /* leave the last known state */ }
      }
    }
  }

  Process { id: clamSet }

  function setClamshell(on) {
    // pkexec prompts, so this cannot be fire-and-forget: re-read when it ends,
    // whether it was authorised or declined.
    clamSet.command = [root.pluginDir + "/scripts/clamshell", on ? "on" : "off"]
    clamSet.running = true
  }

  Connections {
    target: clamSet
    function onExited(code, status) { clam.running = true }
  }

  Timer {
    // Slow: lid policy changes when someone changes it, which is rarely, and
    // it costs a D-Bus round trip.
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: clam.running = true
  }
  // The panel is live only when it is switched on AND not folded away.
  readonly property bool active: root.value("enabled")
    && !(root.value("disableWhenLidClosed") && root.lidClosed)

  // ---- probe ---------------------------------------------------------------
  Process {
    id: probe
    command: [root.pluginDir + "/scripts/touch-tap", "--once"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try {
          parsed = JSON.parse(text)
        } catch (e) {
          root.present = false
          return
        }
        var ifaces = (parsed && parsed.interfaces) || []
        var devs = (parsed && parsed.devices) || []
        var errs = (parsed && parsed.errors) || []

        // EACCES is the `input` group problem, and it is worth its own state.
        // Reporting "no touchscreen" to someone whose touchscreen is sitting
        // right there, working, under a permissions error is the single most
        // confusing thing this plugin could do.
        root.permissionDenied = ifaces.length === 0 && errs.length > 0
          && String(errs.join(" ")).indexOf("Permission denied") >= 0

        root.interfaces = ifaces
        root.devices = devs
        root.present = ifaces.length > 0
        if (ifaces.length > 0) {
          root.model = ifaces[0].model || ifaces[0].name || "Touchscreen"
          root.deviceName = ifaces[0].name || ""
          root.slots = ifaces[0].slots || 0
          root.semiMt = ifaces[0].semi_mt === true
          // ONLY WHEN WE DO NOT ALREADY HAVE THE NAME. This fired on every
          // 10s probe, and each result called applyConfig(), which reloaded
          // Hyprland. prezziej.trackpad guards the same call exactly this way;
          // copying its structure without copying its guard is what produced
          // ~20 compositor reloads a minute here.
          if (!root.hyprNames.length && !names.running) names.running = true
        } else {
          root.model = ""
          root.deviceName = ""
          root.slots = 0
        }
      }
    }
    stderr: SplitParser { onRead: line => { if (line) root.lastError = line } }
  }

  Timer {
    // Cheap and slow. A touchscreen is not hotplugged often; this exists to
    // notice a USB panel appearing, and to recover after a re-login finally
    // grants the input group.
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: probe.running = true
  }

  // ---- Hyprland device names ----------------------------------------------
  //
  // Hyprland's rule, confirmed against `hyprctl devices` on this machine:
  // lowercase the libinput name and replace spaces with dashes. So
  // "SYNA7501:00 06CB:16D6" becomes "syna7501:00-06cb:16d6". Punctuation is
  // kept, which is why the colons survive.
  function hyprSlug(name) {
    return String(name || "").toLowerCase().replace(/ /g, "-")
  }

  Process {
    id: names
    // Reads the Touch: section rather than mice:, which is the one structural
    // difference from the trackpad plugin's version of this. Filtering is done
    // in JS below, because these names contain "." and ":" and building a safe
    // grep -E pattern out of them is a quoting bug waiting to happen.
    command: ["bash", "-lc",
      "hyprctl devices | awk '/^Touch:/{t=1;next} /^[A-Za-z]+:/{t=0} " +
      "t && /^\t\t[^\t]/ {gsub(/^\t+/,\"\"); print}' | sort -u"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var all = text.split("\n").map(s => s.trim()).filter(s => s.length > 0)
        var wanted = {}
        for (var i = 0; i < root.interfaces.length; i++) {
          var slug = root.hyprSlug(root.interfaces[i].name)
          if (slug) wanted[slug] = true
        }
        var out = []
        for (var j = 0; j < all.length; j++) {
          // Accept "<slug>" and Hyprland's collision suffixes "<slug>-2" etc.
          var base = all[j].replace(/-\d+$/, "")
          if (wanted[all[j]] || wanted[base]) out.push(all[j])
        }
        // If the name match found nothing but Hyprland does report exactly one
        // touch device, take it. A slug mismatch should degrade to "drive the
        // only panel there is", not to silently applying no settings -- which
        // is the exact bug the trackpad plugin's comments record having had.
        if (out.length === 0 && all.length === 1) out = all
        root.hyprNames = out
        root.applyConfig()
      }
    }
  }

  // ---- orientation watcher -------------------------------------------------
  Process {
    id: orient
    // 0.3s sampling with the script's 2-sample settle = ~0.6s before a
    // rotation commits, down from 1.6s at the original 0.8s interval. That
    // earlier figure was chosen to be conservative about the sensor's bogus
    // first read, but the settle count already handles that -- the interval was
    // simply making every rotation feel broken. Two samples still absorbs a
    // momentary tilt, which is the thing debouncing is actually for.
    command: [root.pluginDir + "/scripts/orientation", "--watch", "--interval", "0.3"]
    // Only while it can act on the answer. Auto-rotate off and auto-tablet off
    // means the reading changes nothing, and a sensor poll that nobody reads is
    // pure battery on a machine already down to 65% of its design capacity.
    running: root.present && (root.value("autoRotate") || root.value("autoTabletMode"))
    stdout: SplitParser {
      onRead: line => {
        if (!line) return
        var o = null
        try { o = JSON.parse(line) } catch (e) { return }
        if (!o || o.error) return
        root.orientation = o.orientation || "normal"
        root.flat = o.flat === true
        root.orientationSure = o.sure === true
        if (o.sure) root.autoTransform = Number(o.transform) | 0

        // AUTO TABLET MODE IS A GUESS, AND IT SAYS SO.
        //
        // The only posture signal available is orientation, so "not normal and
        // not flat" is the best inference there is: held in portrait or upside
        // down is far more likely to be a tablet in hand than a laptop on a
        // desk. It will still be wrong sometimes, which is exactly why it is
        // opt-in and why the manual toggle exists beside it.
        if (root.value("autoTabletMode") && o.sure && !o.flat) {
          var wantTablet = (o.orientation !== "normal")
          if (wantTablet !== (root.value("tabletMode") === true))
            root.setValue("tabletMode", wantTablet)
        }
        root.applyConfig()
      }
    }
    stderr: SplitParser { onRead: line => { if (line) root.lastError = line } }
  }

  // ---- keyboard / touchpad / monitor discovery ------------------------------
  Process {
    id: peripherals
    // Names come from Hyprland itself rather than from a guess. This laptop's
    // pad is PS/2 and its keyboard is at-translated-set-2; neither is a safe
    // assumption on another machine.
    command: ["bash", "-lc",
      "hyprctl devices | awk '/^Keyboards:/{k=1;t=0;next} /^mice:/{k=0;t=1;next} " +
      "/^[A-Za-z]+:/{k=0;t=0} k && /^\t\t[^\t]/ {gsub(/^\t+/,\"\"); print \"kbd \" $0} " +
      "t && /^\t\t[^\t]/ {gsub(/^\t+/,\"\"); print \"mouse \" $0}'; " +
      "hyprctl monitors -j | head -c 4000"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.split("\n")
        var kbd = "", pad = ""
        for (var i = 0; i < lines.length; i++) {
          var l = lines[i].trim()
          // The built-in keyboard, not the power button or the video bus, both
          // of which Hyprland also lists as keyboards.
          if (l.indexOf("kbd ") === 0) {
            var n = l.substring(4)
            if (!kbd && (n.indexOf("at-translated") >= 0 || n.indexOf("keyboard") >= 0)
                && n.indexOf("power-button") < 0 && n.indexOf("video-bus") < 0)
              kbd = n
          } else if (l.indexOf("mouse ") === 0) {
            var m = l.substring(6)
            if (!pad && (m.indexOf("touchpad") >= 0 || m.indexOf("synaptics") >= 0))
              pad = m
          }
        }
        root.keyboardName = kbd
        root.touchpadName = pad

        var jstart = text.indexOf("[")
        if (jstart >= 0) {
          try {
            var mons = JSON.parse(text.substring(jstart))
            for (var j = 0; j < mons.length; j++) {
              if (mons[j].focused || !root.monitorName) {
                root.monitorName = mons[j].name || ""
                root.monitorScale = mons[j].scale || 1
                if (mons[j].focused) break
              }
            }
          } catch (e) { /* monitors are optional; rotation just stays manual */ }
        }
        root.applyConfig()
      }
    }
  }

  Timer {
    // Runs until the names are known, then stops. Device and monitor names do
    // not change while the session is up; re-reading them every 15s was pure
    // cost, and each read ended in an applyConfig().
    interval: 15000
    running: root.present && (root.keyboardName === "" || root.monitorName === "")
    repeat: true
    triggeredOnStart: true
    onTriggered: peripherals.running = true
  }

  // ---- lid ----------------------------------------------------------------
  Process {
    id: lid
    // Omarchy already ships this, and PAM's fingerprint gate uses the same
    // helper -- exit 0 when closed. Reusing it keeps one definition of "shut"
    // on the machine instead of two that can disagree.
    command: ["/usr/bin/omarchy-hw-laptop-closed"]
    onExited: function(code, status) { root.lidClosed = (code === 0) }
  }

  Timer {
    interval: 3000
    running: root.present && root.value("disableWhenLidClosed")
    repeat: true
    triggeredOnStart: true
    onTriggered: lid.running = true
  }

  onActiveChanged: {
    root.applyConfig()
    // When the panel goes inactive the reader stops, but the last frame it
    // emitted is still sitting in `frame` -- without this the bar keeps showing
    // contacts that lifted long ago.
    if (!root.active) root.frame = ({ n: 0, click: false, f: [] })
  }

  // ---- generated Hyprland config ------------------------------------------
  //
  // WRITTEN AS LUA INTO THE TOGGLES DIR, NOT PUSHED WITH `hyprctl keyword`.
  // Omarchy drives Hyprland from Lua, so `hyprctl keyword` refuses outright:
  // "keyword can't work with non-legacy parsers. Use eval." Files under
  // toggles/hypr are sourced AFTER the user's own config on every reload, which
  // is both how these survive a reboot and how they win over the defaults
  // without editing a single file the user owns.
  function luaConfig() {
    var lines = [
      "-- Generated by prezziej.touchscreen. Edits here are overwritten.",
      "-- Delete this file and run `hyprctl reload` to restore Omarchy's defaults.",
      ""
    ]

    var t = root.effectiveTransform

    for (var i = 0; i < root.hyprNames.length; i++) {
      lines.push("hl.device({")
      lines.push("  name = " + JSON.stringify(root.hyprNames[i]) + ",")
      lines.push("  enabled = " + (root.active ? "true" : "false") + ",")
      // The digitizer must rotate WITH the display or touches land at right
      // angles to the finger. Same transform, always -- that is the whole
      // reason auto-rotate lives in the touchscreen plugin rather than in a
      // display applet.
      lines.push("  transform = " + String(t) + ",")
      var out = String(root.value("output") || "")
      if (out.length > 0)
        lines.push("  output = " + JSON.stringify(out) + ",")
      lines.push("})")
      lines.push("")
    }

    // ---- display rotation ---------------------------------------------------
    //
    // Only when auto-rotate is on AND we know the monitor. A partial
    // hl.monitor() would be worse than none: Omarchy sets scale in its own
    // monitors.lua, and re-emitting the monitor without that scale would reset
    // a 4K panel to 1x and make everything unreadable. So the live scale is
    // read back from hyprctl and echoed here.
    if (root.value("autoRotate") && root.monitorName && root.orientationSure) {
      lines.push("-- Display rotation, following the accelerometer.")
      lines.push("hl.monitor({")
      lines.push("  output = " + JSON.stringify(root.monitorName) + ",")
      lines.push("  mode = \"preferred\",")
      lines.push("  position = \"auto\",")
      lines.push("  scale = " + Number(root.monitorScale).toFixed(6) + ",")
      lines.push("  transform = " + String(t) + ",")
      lines.push("})")
      lines.push("")
    }

    // ---- tablet mode --------------------------------------------------------
    //
    // Folded back, the keyboard faces whatever the machine is resting on and
    // the touchpad sits under your palm. This laptop reports no
    // SW_TABLET_MODE, so nothing disables them for you -- which is the whole
    // reason this exists.
    if (root.tabletMode) {
      lines.push("-- Tablet mode: the keyboard and pad are facing the wrong way.")
      if (root.value("tabletDisablesKeyboard") && root.keyboardName)
        lines.push("hl.device({ name = " + JSON.stringify(root.keyboardName) + ", enabled = false })")
      if (root.value("tabletDisablesTouchpad") && root.touchpadName)
        lines.push("hl.device({ name = " + JSON.stringify(root.touchpadName) + ", enabled = false })")
      lines.push("")
    }

    return lines.join("\n") + "\n"
  }

  // A DROPPED WRITE HERE CAN LEAVE THE KEYBOARD DISABLED.
  //
  // applyConfig() is called from settings changes, the orientation watcher and
  // the device-discovery poll, so several can land within one tick. Setting
  // `running = true` on a Process that is already running does not queue a
  // second run -- it is simply lost. Observed: turning tablet mode OFF left
  // the generated Lua still carrying
  //     hl.device({ name = "at-translated-set-2-keyboard", enabled = false })
  // because the write that would have removed it was swallowed by an
  // in-flight one.
  //
  // For a bar widget that would be a cosmetic bug. For a feature whose whole
  // job is disabling the keyboard, the "put it back" write is the one that
  // must never be dropped. So a coalescing flag: anything asked for during a
  // write is re-run once that write finishes.
  Process {
    id: writer
    onExited: function(code, status) {
      if (root.writePending) {
        root.writePending = false
        root.applyConfig()
      }
    }
  }

  property bool writePending: false
  // The last config we actually wrote. Compared before every write.
  property string lastWritten: ""

  function applyConfig() {
    if (!root.hyprNames.length) return

    // NEVER RELOAD HYPRLAND FOR A CONFIG THAT HAS NOT CHANGED.
    //
    // applyConfig() is called from the settings, the 10s device probe, the 15s
    // peripherals poll and the orientation watcher, and it used to write and
    // `hyprctl reload` on every one of them regardless of whether anything
    // differed. Measured consequence: ~20 reloads a MINUTE, sustained.
    //
    // A reload re-applies hl.monitor(), which Hyprland reports to
    // xdg-desktop-portal as a monitor layout change, which makes every
    // input-capture client (lan-mouse here) tear down and rebuild its session.
    // That churn ran for twenty minutes and ended with the portal wedging,
    // Hyprland's ANR watchdog firing, and the compositor aborting inside
    // CANRManager::runDialog.
    //
    // The generated text is the state. If it is identical, there is nothing to
    // apply and nothing to tell anyone about.
    var next = root.luaConfig()
    if (next === root.lastWritten) return

    if (writer.running) { root.writePending = true; return }
    root.lastWritten = next
    // Quoted heredoc delimiter: the Lua is data and must not be expanded by the
    // shell on its way to disk.
    writer.command = ["bash", "-lc",
      "mkdir -p " + JSON.stringify(root.stateDir + "/toggles/hypr") +
      " && cat > " + JSON.stringify(root.togglesFile) + " <<'OMATOUCH_EOF'\n" +
      next + "OMATOUCH_EOF\n" +
      "hyprctl reload >/dev/null"]
    writer.running = true
  }

  Process { id: reverter }

  function revertToOmarchyDefaults() {
    reverter.command = ["bash", "-lc",
      "rm -f " + JSON.stringify(root.togglesFile) + "; hyprctl reload >/dev/null"]
    reverter.running = true
  }

  // ---- the reader ---------------------------------------------------------
  Process {
    id: reader
    command: {
      var c = [root.pluginDir + "/scripts/touch-tap"]
      var dev = String(root.value("device") || "")
      if (dev.length > 0) c.push("--prefer", dev)
      return c
    }
    // Only while it is worth reading: a HUD that is switched off, a panel that
    // is disabled, or a folded lid all mean the stream is pure cost.
    running: root.present && root.value("hud") && root.active

    // SplitParser, never StdioCollector: this stream has no end, and collecting
    // it would grow a string until the shell dies.
    stdout: SplitParser {
      onRead: line => {
        if (!line) return
        try {
          root.frame = JSON.parse(line)
        } catch (e) {
          // A partial line is not worth a log entry at 60 Hz.
        }
      }
    }
    stderr: SplitParser { onRead: line => { if (line) root.lastError = line } }
  }

  // ---- the HUD ------------------------------------------------------------
  Loader {
    active: root.present && root.value("hud") && root.active
    sourceComponent: Overlay {
      frame: root.frame
      minContacts: Number(root.value("hudMinContacts")) || 1
      style: String(root.value("hudStyle") || "ripple")
    }
  }

  // ---- IPC ----------------------------------------------------------------
  IpcHandler {
    // A LITERAL, not a binding. Quickshell's IpcHandler::updateRegistration
    // does an unchecked dynamic_cast on this path, and re-evaluating it on
    // every plugin hot-reload segfaults the whole shell -- the omatrackpad
    // install script counts 68 of 131 crash reports on that one signature.
    // The id is a constant anyway; there is nothing to bind to.
    target: "prezziej.touchscreen"

    function toggle(): void { root.setValue("enabled", !root.value("enabled")) }
    function enable(): void { root.setValue("enabled", true) }
    function disable(): void { root.setValue("enabled", false) }
    function hud(on: bool): void { root.setValue("hud", on) }
    function rotate(t: int): void { root.setValue("transform", t) }
    function tablet(on: bool): void { root.setValue("tabletMode", on) }
    function tabletToggle(): void { root.setValue("tabletMode", !root.tabletMode) }
    function autorotate(on: bool): void { root.setValue("autoRotate", on) }
    function clamshell(on: bool): void { root.setClamshell(on) }
    function reset(): void { root.resetSettings() }
    function status(): string {
      return JSON.stringify({
        present: root.present,
        permissionDenied: root.permissionDenied,
        model: root.model,
        device: root.deviceName,
        hyprNames: root.hyprNames,
        slots: root.slots,
        enabled: root.value("enabled"),
        active: root.active,
        lidClosed: root.lidClosed,
        contacts: root.contacts,
        clamshell: root.clamshell,
        lidPolicy: root.lidPolicy,
        orientation: root.orientation,
        orientationSure: root.orientationSure,
        flat: root.flat,
        transform: root.effectiveTransform,
        autoRotate: root.value("autoRotate"),
        tabletMode: root.tabletMode,
        keyboard: root.keyboardName,
        touchpad: root.touchpadName,
        monitor: root.monitorName
      })
    }
  }
}
