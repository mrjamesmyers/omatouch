# omatouch

A touchscreen plugin for the Omarchy shell: enable or disable the panel, bind
it to the right monitor, correct its rotation, and see every contact drawn
where your finger actually is.

Companion to `omatrackpad`. The two deliberately do not overlap
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

## Tablet mode and clamshell

This laptop folds into a tablet, and lives on a stand in a car. Two settings
follow from that, and both reach outside the plugin's usual territory.

**Tablet mode** locks the keyboard and trackpad when the screen is folded back,
so a hand on the underside does not type. Orientation follows the
accelerometer — with a two-sample settle, because the first reading after a
wake is reliably a bogus `[0, 0, 1000]` and acting on it rotates the screen for
no reason.

**Clamshell mode** keeps the machine running with the lid shut. That is
systemd-logind policy in `/etc` rather than anything in your Hyprland config,
so `scripts/clamshell` reads the effective value over D-Bus (no root needed,
so the panel can always show the truth) and changes it through pkexec.

It uses `systemctl reload`, never `restart`. Restarting `systemd-logind` tears
down the login session it owns — the compositor and everything in it goes with
it. That was learned the hard way on this machine: a restart to apply this very
setting took the desktop down and back up.

The trade is real and stated in the tool: a closed lid no longer sleeps the
machine, so it will flatten the battery if closed and left in a bag. Right for
a car computer, wrong for a laptop you carry.

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

## When it does not work

    ./scripts/doctor

This plugin was written against one digitizer. When a plugin does not work on
hardware its author never had, the user has no way to tell *which* of a dozen
things is wrong — they get a screen that does not respond and a plugin that
says nothing.

The doctor checks the things that actually go wrong, and each finding says what
to do about it: `input` group membership (and whether *this session* predates
it, which is the commonest one), whether a direct-touch digitizer exists at
all, whether the one picked is a stylus surface rather than a finger surface,
whether Hyprland sees it, whether it is bound to an output, whether the
digitizer's aspect ratio matches the monitor it is mapped to, whether the
rotation setting matches the monitor's transform, and whether the installed
copy matches your checkout.

The geometry check is the one worth knowing about. A digitizer reports its own
coordinate range; if that aspect ratio does not match the monitor's, touch will
land offset from your finger. That is the commonest multi-monitor complaint on
any compositor, and it is arithmetic rather than something you have to notice.

Reporting a problem? `./scripts/doctor --json` is what to attach.

## Hardware

`hardware.json` records the digitizers this has actually been run against —
currently one. The doctor tells you whether yours is among them.

An unknown digitizer is not a warning, it is the expected case. If the plugin
works on yours, adding an entry is the most useful thing you can contribute;
if it does not, that is worth recording too. The `quirks` field is the part
that compounds: the specific thing that had to be done for that device, so the
next person with it does not rediscover it.

## Tested against

Synaptics `SYNA7501:00 06CB:16D6` (i2c) in a Lenovo Yoga 710-15IKB — a 2017
convertible, which is exactly the case the Test tab exists for.
