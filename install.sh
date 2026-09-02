#!/bin/bash
#
# omatouch installer. Idempotent: run it again after a git pull.
#
#   ./install.sh
#
# Stock Omarchy only: this installs a bar widget and its service, and nothing
# else. No dock, no panel plugin, no third-party shell components.
#
# NO UDEV RULE, and nothing here needs root. The trackpad plugin ships one
# because a Bluetooth pad's battery is only reachable through a raw HID report;
# a touchscreen has no battery and is read straight off its evdev node. What it
# DOES need is membership of the `input` group, which is a one-time
# `sudo usermod -aG input $USER` plus a fresh login -- and the plugin detects
# and explains that itself rather than failing silently.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_ID="prezziej.touchscreen"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

say()  { printf '  \033[1;32mok\033[0m    %s\n' "$1"; }
skip() { printf '  \033[1;33mskip\033[0m  %s\n' "$1"; }
warn() { printf '  \033[1;31mwarn\033[0m  %s\n' "$1" >&2; }

# --- the plugin -------------------------------------------------------------

# Copied, not symlinked: the shell's hot-reload watcher does not see writes
# through a symlink.
if [[ -e "$PLUGIN_DIR" && ! -L "$PLUGIN_DIR" && ! -f "$PLUGIN_DIR/manifest.json" ]]; then
  warn "$PLUGIN_DIR exists and isn't ours — move it aside first."
  exit 1
fi
[[ -L "$PLUGIN_DIR" ]] && rm "$PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR/scripts"

# Explicit list, not a glob. Fixtures must not ship into the plugin dir: the
# shell compiles every .qml it finds there.
#
# COPY ONLY WHAT CHANGED. The shell hot-reloads a plugin once per changed FILE,
# and Quickshell's IpcHandler::updateRegistration does an unchecked
# dynamic_cast on that path -- the omatrackpad installer records 68 of 131
# crash reports on that one signature. A blind `cp -f` of every file fires a
# reload storm and rolls the dice each time; copying only what differs makes
# the usual edit-one-file run fire once, and a no-op re-run fire not at all.
install_changed() { # src dst
  cmp -s "$1" "$2" 2>/dev/null && return 0
  cp -f "$1" "$2"
}

for f in manifest.json Service.qml Overlay.qml Hud.qml BarWidget.qml Panel.qml Touchscreen.qml; do
  install_changed "$ROOT/$f" "$PLUGIN_DIR/$f"
done

# Same rule for the scripts, and for the same reason. `install` copies
# unconditionally, so this loop used to rewrite all three on a no-op re-run --
# three more changed files, three more rolls of the dice above. The -x test is
# what `install -m 755` was really here for: a script that lands
# non-executable never runs, and identical content does not fix its mode.
install_changed_exec() { # src dst
  cmp -s "$1" "$2" 2>/dev/null && [[ -x "$2" ]] && return 0
  install -m 755 "$1" "$2"
}

for f in touch-tap orientation clamshell doctor; do
  install_changed_exec "$ROOT/scripts/$f" "$PLUGIN_DIR/scripts/$f"
done

say "plugin installed to $PLUGIN_DIR"

# --- the input group --------------------------------------------------------
#
# Checked, never changed. Adding someone to a group is a privileged, durable
# change to their account, and an installer that does it silently -- for a bar
# widget -- has overstepped. Report it and let them decide.
if id -nG | tr ' ' '\n' | grep -qx input; then
  say "input group: this session can read /dev/input"
elif id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
  skip "input group: granted, but THIS session predates it — log out and back in"
else
  skip "input group: not a member — the HUD will not draw"
  printf '        sudo usermod -aG input %s   (then log out and back in)\n' "$USER"
fi

# --- reload -----------------------------------------------------------------
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 && say "shell rescanned" || true
fi

echo
echo "  Add the widget from the bar settings, or:"
echo "    omarchy plugin enable $PLUGIN_ID --section right"
echo "  Edits to an already-loaded plugin need \`omarchy restart shell\`."
