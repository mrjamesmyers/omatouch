# omatouch

A touchscreen plugin for the Omarchy shell: enable or disable the panel, bind
it to the right monitor, correct its rotation, and see every contact drawn
where your finger actually is.

Companion to [omatrackpad](../omatrackpad). The two deliberately do not overlap
— `trackpad-tap` rejects `INPUT_PROP_DIRECT` devices and `touch-tap` requires
them, so exactly one of them claims any given surface.

## Why it isn't just the trackpad plugin with a different name

The trackpad HUD draws a **scale model** of the pad, because a trackpad is not
the screen: the only way to show where a finger is, is to draw a small picture
of the surface and put a dot on it.

A touchscreen inverts that. The finger is already resting on the pixel it is
pointing at, so a scale model would be a picture of the screen, drawn on that
screen, underneath the hand it depicts. The trackpad plugin's own source says
so, in the comment where it rejects direct-touch devices.

So there is no plate here. Contacts are drawn at their true display
coordinates on a full-screen click-through overlay, and the settings are the
ones a touchscreen actually has — enabled, rotation, output binding — rather
than tap-to-click and scroll acceleration, which an absolute-positioned
digitizer does not have.

## Install

```bash
./install.sh
omarchy plugin enable prezziej.touchscreen --section right
```

Nothing here needs root.

## The `input` group

The HUD reads the evdev node directly, which requires membership of the
`input` group:

```bash
sudo usermod -aG input $USER
```

**Then log out and back in.** Group membership is fixed at login, and the
shell inherits it from the user's systemd manager — so `omarchy restart shell`
is *not* enough, and neither is a new terminal.

Without it the plugin still loads, the bar widget still appears, and the panel
explains the problem rather than silently reporting no hardware. That
distinction is deliberate: a permissions failure and an absent touchscreen look
identical from userspace and have completely different fixes.

## Settings

| Setting | What it does |
|---|---|
| Touchscreen | Master enable/disable. The one you reach for on a convertible. |
| Off when the lid is shut | A folded convertible presses its screen against the base, which reads as phantom touches. Uses Omarchy's own `omarchy-hw-laptop-closed`. |
| Rotation | `transform` 0–7, for a digitizer mounted at a different rotation from the display. |
| Bound to monitor | Which output the panel drives. Empty lets Hyprland decide, which is right until a second screen is plugged in. |
| Contact HUD | Draw contacts on the glass. |
| HUD style | `ripple`, `dot`, or `crosshair`. Crosshair reads against screen content; dot is quietest. |

Settings are written as Lua into `~/.local/state/omarchy/toggles/hypr/touchscreen.lua`,
which Hyprland sources *after* the user's own config on every reload. That is
how they survive a reboot and win over the defaults without editing a single
file you own. `hyprctl keyword` is not used, because Omarchy drives Hyprland
from Lua and the compositor refuses: *"keyword can't work with non-legacy
parsers."*

## The reader

`scripts/touch-tap` streams one compact JSON object per `SYN_REPORT` frame:

```json
{"n":2,"click":false,"f":[{"x":0.41,"y":0.62,"p":0.31,"id":7}]}
```

`x` and `y` are normalised 0..1 in **display** space. Stdlib only — no
python-evdev, no libinput CLI.

Useful flags:

```bash
./scripts/touch-tap --once                    # device info and exit
./scripts/touch-tap --synth fixtures/p.bin    # write a synthetic pinch
./scripts/touch-tap --replay fixtures/p.bin --speed 0
./scripts/touch-tap --swap-xy --invert-y      # orientation, when a panel lies
```

`--synth`/`--replay` exist so the decoder can be exercised with no hardware and
no `input` group — which is the situation this plugin was written in.

Orientation is an explicit knob rather than a convention. `trackpad-tap` can
assert that evdev's touchpad convention already matches screen orientation; a
touchscreen cannot, because the digitizer is bonded to the panel in whatever
rotation the OEM chose.

## Tested against

Synaptics `SYNA7501:00 06CB:16D6` (i2c) in a Lenovo Yoga 710-15IKB — a 2017
convertible, which is exactly the case the Test tab exists for.
