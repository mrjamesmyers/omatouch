#!/usr/bin/env bash
#
# omatouch smoke tests.
#
# READ-ONLY ON A LIVE DESKTOP. It never installs a package, never writes to
# /etc, never touches a udev rule, never asks for sudo, never lets a real
# pkexec run (a fake one goes first on PATH), never enables clamshell or tablet
# mode, never writes or deletes ~/.local/state/omarchy/toggles/hypr/*, never
# runs `hyprctl reload` or `omarchy restart shell`, never opens a window or
# sends a notification, and never uses pkill. Everything it creates lives in one
# temp dir it removes on the way out; the installer is exercised against a
# throwaway $HOME, never the real one.
#
# The installer's one `omarchy-shell shell rescanPlugins` call is INTERCEPTED by
# a stub first on PATH, and a canary asserts the interception happened. This
# file used to claim the sandbox PATH "cannot find omarchy-shell", which was
# false -- /usr/bin/omarchy-shell is right there. What kept the live shell safe
# was `env -i` dropping OMARCHY_PATH, which the real binary happens to require.
# Safety by accident is not safety, so it is now by construction.
#
# It needs no hardware. This machine has no touchscreen, no accel_3d and no
# lid, so every hardware-shaped check branches on detection and asserts the
# honest outcome in both directions -- that is what keeps the suite meaningful
# on the Yoga and green on a desktop.
#
# NO `set -e`, deliberately: `((fails++))` evaluates to 0 the first time it
# runs, which is a non-zero exit status, and would abort the suite at exactly
# the first failure it exists to report.

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

fails=0
ok()  { printf '   ok  %s\n' "$1"; }
bad() { printf ' FAIL  %s\n' "$1"; ((fails++)); }
check() { [[ "$2" == "$3" ]] && ok "$1" || { printf ' FAIL  %s (want %q, got %q)\n' "$1" "$2" "$3"; ((fails++)); }; }
skip() { printf ' skip  %s\n' "$1"; }

# Python and Lua checks report one line per assertion so the counters stay in
# this shell. Fed through process substitution, NOT a pipe: a pipe would run
# the loop in a subshell and every `((fails++))` would be thrown away with it.
#
# EVERY BLOCK MUST PRINT THE SENTINEL AS ITS LAST LINE, and this insists on it.
# A block that raises part way through writes its traceback to stderr, which
# nothing here was reading, and simply STOPS -- every assertion after the point
# it died vanishes without a word while the suite still says "All green".
# Measured, not theorised: dropping the `readonly` from Service.qml's
# `readonly property var defaults` makes the manifest block's regex return None,
# and the two key-set checks -- the ones that catch a settings control writing a
# key nothing reads -- disappeared. 90 checks became 88 and the suite stayed
# green. So the count is now load-bearing, and the block's stderr is quoted back.
SENTINEL="__omatouch_block_complete__"
report() { # label
  local label="${1:-python block}" line saw_end=0
  while IFS= read -r line; do
    case "$line" in
      "$SENTINEL") saw_end=1 ;;
      "ok "*)  ok  "${line#ok }" ;;
      "bad "*) bad "${line#bad }" ;;
      "note "*) printf '       %s\n' "${line#note }" ;;
      *)       bad "unparseable check result: $line" ;;
    esac
  done
  ((saw_end)) || bad "$label: the block died before its last check -- $(tail -3 "$TMP/py.err" 2>/dev/null | tr '\n' ' ')"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/omatouch-smoke.XXXXXX")"
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Comment strippers. THE POINT OF THESE: this codebase warns about its own
# hazards in prose, so a naive grep for a risky pattern matches the comment
# telling you not to do it and reports the danger as present. Every source
# assertion below greps the STRIPPED text.
# Only the QML one: there was a matching shell/python stripper here that nothing
# ever called, and an unused helper in a test suite reads like coverage that
# does not exist. The shell and python sources are asserted by running them.
qcode() { sed -E 's,(^|[[:space:]])//.*$,\1,' "$1" 2>/dev/null; }  # qml, js

# python3 -B everywhere: importing scripts/touch-tap for a table test would
# otherwise drop __pycache__ into the repo, which is state left behind.
PY="python3 -B"

printf '\n  omatouch smoke  (%s)\n\n' "$ROOT"

# ---------------------------------------------------------------------------
# The fixture and the decoder. No hardware, no permissions, fully deterministic.
# ---------------------------------------------------------------------------

# FIRST, because every decoder assertion below is only as good as the fixture.
# If --synth and the committed .bin ever drift, those tests keep passing while
# measuring a stale artefact instead of the current decoder.
"$ROOT/scripts/touch-tap" --synth "$TMP/regen.bin" 2>/dev/null
if cmp -s "$TMP/regen.bin" "$ROOT/fixtures/pinch-synth.bin"; then
  ok "--synth regenerates fixtures/pinch-synth.bin byte for byte"
else
  bad "--synth no longer regenerates fixtures/pinch-synth.bin -- the decoder tests are measuring a stale fixture"
fi

# --speed 0 is mandatory. The default is 1.0, which sleeps per frame and turns
# a millisecond test into a wall-clock one.
"$ROOT/scripts/touch-tap" --replay "$ROOT/fixtures/pinch-synth.bin" --speed 0 \
  >"$TMP/frames.jsonl" 2>"$TMP/replay.err"
check "--replay exits 0" 0 $?

report "replay decoder" < <($PY - "$TMP/frames.jsonl" 2>"$TMP/py.err" <<'PYEOF'
import json, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

L = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
body, last = L[:-1], (L[-1] if L else None)

chk("replay: 48 contact frames plus one lift", len(L) == 49, "got %d lines" % len(L))

# Protocol B sends the tracking ids ONCE, on the fixture's first frame, and
# thereafter only the axes that changed. If the decoder ever stops carrying
# slot state across SYN_REPORTs the contacts lose their id, frame() drops them,
# and n collapses -- the "stream of half-updated coordinates" the Surface
# docstring warns about.
chk("replay: both contacts present in every frame", all(f["n"] == 2 for f in body),
    "n values: %s" % sorted({f["n"] for f in body}))
chk("replay: tracking ids survive every SYN_REPORT",
    all({c["id"] for c in f["f"]} == {200, 201} for f in body))

# A SHAPE CHECK, NOT THE CLAMP TEST -- the fixture stays inside the ABS range,
# so this passes with the clamp deleted. The clamp has its own block below.
# What this does catch is a swap/invert or a normalisation that inverts a sign.
chk("replay: every coordinate stays inside 0..1",
    all(0.0 <= c[k] <= 1.0 for f in body for c in f["f"] for k in ("x", "y")))

# The single trailing {"n":0} is the ONLY thing that tells the overlay the hand
# is gone. Lose it and the HUD stays lit over whatever was just tapped.
chk("replay: exactly one terminating n:0 frame, and it is last",
    last == {"n": 0, "click": False, "f": []} and not any(f["n"] == 0 for f in body))

# A pinch that opens. Separation can only grow if slot state is being carried
# forward; a decoder re-deriving each frame from the events it just saw would
# produce a jitter, not a monotone.
seps = [abs(f["f"][0]["x"] - f["f"][1]["x"]) for f in body if f["n"] == 2]
chk("replay: contact separation increases monotonically",
    len(seps) > 2 and all(b > a for a, b in zip(seps, seps[1:])),
    "%.3f -> %.3f" % (seps[0], seps[-1]) if seps else "no frames")
print("__omatouch_block_complete__")
PYEOF
)

# THE CLAMP, TESTED DIRECTLY, because the fixture cannot reach it. "replay:
# every coordinate stays inside 0..1" above sounds like the clamp test and is
# not one: --synth only ever emits raws inside the advertised ABS range, so
# deleting `max(0.0, min(1.0, ...))` out of Surface._norm leaves that assertion
# green -- measured. Real digitizers do overshoot their advertised minimum and
# maximum at the bezel, and an unclamped contact draws its ripple off the edge
# of the display, so the out-of-range case needs saying out loud.
report "decoder clamp" < <($PY - "$ROOT/scripts/touch-tap" 2>"$TMP/py.err" <<'PYEOF'
import importlib.machinery, importlib.util, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

ld = importlib.machinery.SourceFileLoader("tt", sys.argv[1])
tt = importlib.util.module_from_spec(importlib.util.spec_from_loader("tt", ld))
ld.exec_module(tt)

s = tt.Surface({tt.ABS_MT_POSITION_X: (0, 3999, 0), tt.ABS_MT_POSITION_Y: (0, 2239, 0)})
lo = s._norm(tt.ABS_MT_POSITION_X, -500)
hi = s._norm(tt.ABS_MT_POSITION_Y, 9999)
chk("decoder: a raw below the advertised ABS minimum clamps to 0.0", lo == 0.0, repr(lo))
chk("decoder: a raw above the advertised ABS maximum clamps to 1.0", hi == 1.0, repr(hi))
# And the clamp must not be a floor on everything: an in-range raw still scales.
mid = s._norm(tt.ABS_MT_POSITION_X, 2000)
chk("decoder: an in-range raw still scales linearly", abs(mid - 0.500125) < 1e-6, repr(mid))
# An axis the device does not advertise has no range to normalise against, and
# frame() drops the contact on None rather than dividing by zero.
chk("decoder: an unadvertised axis normalises to None",
    s._norm(tt.ABS_MT_PRESSURE, 10) is None)
print("__omatouch_block_complete__")
PYEOF
)

# Service.qml stops and restarts the reader whenever the HUD is toggled, the
# panel is disabled or the lid shuts. Without the SIGPIPE handler each of those
# writes a BrokenPipeError traceback into the shell log, which reads like a
# crash. Subprocess, not import: the handler is installed under __main__.
"$ROOT/scripts/touch-tap" --replay "$ROOT/fixtures/pinch-synth.bin" --speed 0 \
  2>"$TMP/pipe.err" | head -1 >/dev/null
pipe_status=${PIPESTATUS[0]}
# 0 or 141 (128+SIGPIPE), and which one is a genuine race: the whole fixture is
# ~5KB and the pipe buffer is 64KB, so the writer sometimes finishes before
# `head` ever leaves. Both are quiet deaths. What must NEVER happen is Python
# catching the signal itself -- that is exit 1 or 120 WITH a traceback on
# stderr, which is the state the SIG_DFL handler exists to prevent. So the
# stderr byte count below is the real assertion; the status is the sanity check.
case "$pipe_status" in
  0|141) ok "reader dies quietly when its consumer closes the pipe (exit $pipe_status)" ;;
  *)     bad "reader exited $pipe_status on a closed pipe -- Python is handling SIGPIPE again" ;;
esac
check "reader writes no traceback when its consumer closes the pipe" 0 "$(stat -c %s "$TMP/pipe.err")"

# ---------------------------------------------------------------------------
# Classification. touch-tap and trackpad-tap must stay disjoint: exactly one of
# them may claim any given surface.
# ---------------------------------------------------------------------------

report "classifier table" < <($PY - "$ROOT/scripts/touch-tap" 2>"$TMP/py.err" <<'PYEOF'
import importlib.machinery, importlib.util, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

# SourceFileLoader, not spec_from_file_location: the latter returns None for a
# file with no .py extension, which is every script in this plugin.
ld = importlib.machinery.SourceFileLoader("tt", sys.argv[1])
tt = importlib.util.module_from_spec(importlib.util.spec_from_loader("tt", ld))
ld.exec_module(tt)

XY = {tt.ABS_MT_POSITION_X: (0, 3999, 0), tt.ABS_MT_POSITION_Y: (0, 2239, 0)}

def classify(props, udev, ranges=XY):
    # Monkeypatching the two readers, not creating a uinput device: a synthetic
    # INPUT_PROP_DIRECT node is visible to the running compositor, which would
    # probe it, write a Lua toggle and reload the live desktop. This tests the
    # same decision with none of that blast radius, and needs no root.
    tt.device_props = lambda fd: set(props)
    tt.udev_props = lambda path: dict(udev)
    return tt.classify(None, "/dev/input/eventTEST", ranges)

kind, why = classify({tt.INPUT_PROP_DIRECT}, {})
chk("classify: INPUT_PROP_DIRECT is a touchscreen", (kind, why) == ("touchscreen", "INPUT_PROP_DIRECT"),
    repr((kind, why)))

kind, why = classify(set(), {"ID_INPUT_TOUCHSCREEN": "1"})
chk("classify: udev ID_INPUT_TOUCHSCREEN is a touchscreen", kind == "touchscreen", repr((kind, why)))

# The inverse of trackpad-tap. If this ever starts accepting an indirect pad,
# the full-screen HUD draws contacts at trackpad coordinates over the desktop
# and both plugins fight for one device.
kind, why = classify({tt.INPUT_PROP_POINTER, tt.INPUT_PROP_BUTTONPAD}, {"ID_INPUT_TOUCHPAD": "1"})
chk("classify: a touchpad is refused, and says which script to use",
    kind is None and "trackpad-tap" in why, repr((kind, why)))

kind, why = classify({tt.INPUT_PROP_POINTER}, {"ID_INPUT_TABLET": "1"})
chk("classify: a graphics tablet is refused", kind is None and "trackpad-tap" in why, repr((kind, why)))

kind, why = classify({tt.INPUT_PROP_POINTER, tt.INPUT_PROP_BUTTONPAD}, {})
chk("classify: a bare indirect pointing surface is refused", kind is None, repr((kind, why)))

kind, why = classify({tt.INPUT_PROP_ACCELEROMETER}, {})
chk("classify: an accelerometer is refused", (kind, why) == (None, "accelerometer"), repr((kind, why)))

kind, why = classify({tt.INPUT_PROP_POINTING_STICK}, {})
chk("classify: a pointing stick is refused", kind is None, repr((kind, why)))

# No position axes means nothing to draw, whatever the props say.
kind, why = classify({tt.INPUT_PROP_DIRECT}, {}, {})
chk("classify: no multitouch position axes is refused",
    (kind, why) == (None, "no multitouch position axes"), repr((kind, why)))
print("__omatouch_block_complete__")
PYEOF
)

# The disjointness promise, checked against this machine's real device nodes
# rather than a table. Read-only: each node is opened O_RDONLY|O_NONBLOCK for
# two ioctls and closed. Skips cleanly when the sibling plugin is not checked
# out, and reports honestly when nothing is fitted.
TRACKPAD_TAP=""
for c in "$HOME/.config/omarchy/plugins/prezziej.trackpad/scripts/trackpad-tap" \
         "$HOME/Projects/omatrackpad/scripts/trackpad-tap"; do
  [[ -x "$c" ]] && { TRACKPAD_TAP="$c"; break; }
done
if [[ -z "$TRACKPAD_TAP" ]]; then
  skip "classifier disjointness: omatrackpad's trackpad-tap not found on this machine"
else
  report "classifier disjointness" < <($PY - "$ROOT/scripts/touch-tap" "$TRACKPAD_TAP" 2>"$TMP/py.err" <<'PYEOF'
import glob, importlib.machinery, importlib.util, os, re, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

def load(name, path):
    ld = importlib.machinery.SourceFileLoader(name, path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, ld))
    ld.exec_module(mod)
    return mod

tt = load("tt", sys.argv[1])
tp = load("tp", sys.argv[2])

both, screens, pads, unreadable, total = [], [], [], 0, 0
for path in sorted(glob.glob("/dev/input/event*"), key=lambda p: int(re.sub(r"\D", "", p) or 0)):
    total += 1
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        unreadable += 1
        continue
    try:
        a = tt.classify(fd, path, tt.read_ranges(fd))[0]
        b = tp.classify(fd, path, tp.read_ranges(fd))[0]
    finally:
        os.close(fd)
    if a:
        screens.append(path)
    if b:
        pads.append(path)
    if a and b:
        both.append(path)

chk("no /dev/input node is claimed by both touch-tap and trackpad-tap",
    not both, "both claim %s" % both)
print("note (%d evdev nodes: %d touchscreen, %d pad, %d not openable)"
      % (total, len(screens), len(pads), unreadable))
print("__omatouch_block_complete__")
PYEOF
)
fi

# ---------------------------------------------------------------------------
# The permissions story. Service.qml sets permissionDenied by searching for the
# literal substring below, and BarWidget stays VISIBLE only in that state.
# ---------------------------------------------------------------------------

# LC_ALL=C: strerror is locale-sensitive, and the string Service.qml searches
# for is the English one.
LC_ALL=C "$ROOT/scripts/touch-tap" --once >"$TMP/once.json" 2>/dev/null
once_status=$?
if $PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(k in d for k in ("interfaces","devices","errors")) else 1)' "$TMP/once.json"; then
  ok "--once always prints JSON with interfaces/devices/errors"
else
  bad "--once did not print JSON with all three keys: $(head -c 120 "$TMP/once.json")"
fi

if $PY -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["interfaces"] else 1)' "$TMP/once.json"; then
  present=yes
  check "--once exits 0 when a touchscreen is fitted" 0 "$once_status"
else
  present=no
  # Exit 1 with an empty, well-formed report is how "nothing fitted" is said.
  # It must never be a traceback or an empty stdout.
  check "--once exits 1 when no touchscreen is fitted" 1 "$once_status"
fi

if [[ $EUID -eq 0 ]]; then
  skip "EACCES reporting: running as root, which can open anything"
else
  # A mode-000 regular file stands in for a /dev/input node this user cannot
  # open. Named explicitly, so probe() reports it rather than skipping it.
  : >"$TMP/denied"
  chmod 000 "$TMP/denied"
  LC_ALL=C "$ROOT/scripts/touch-tap" --once --device "$TMP/denied" >"$TMP/denied.json" 2>/dev/null
  denied_status=$?
  chmod 600 "$TMP/denied"
  check "a node it cannot open exits 1" 1 "$denied_status"
  report "EACCES reporting" < <($PY - "$TMP/denied.json" 2>"$TMP/py.err" <<'PYEOF'
import json, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("bad a permissions failure is still JSON, not a traceback -- %s" % e)
    print("__omatouch_block_complete__")
    raise SystemExit(0)

chk("a permissions failure is still JSON, not a traceback", isinstance(d.get("errors"), list))
errs = " ".join(d.get("errors") or [])
# Service.qml does exactly this: errs.join(" ").indexOf("Permission denied").
# Reword the error and someone outside the `input` group gets a hidden widget
# and "No touchscreen" for hardware sitting right there, working.
chk('the error carries the literal substring "Permission denied"',
    "Permission denied" in errs, repr(errs[:120]))
print("__omatouch_block_complete__")
PYEOF
)
fi

# The other half of that contract. If these two ever drift the state is
# unreachable, so pin the string in the consumer too.
if qcode "$ROOT/Service.qml" | grep -qF '"Permission denied"'; then
  ok 'Service.qml still searches for the literal "Permission denied"'
else
  bad 'Service.qml no longer searches for "Permission denied" -- permissionDenied can never be set'
fi

# ---------------------------------------------------------------------------
# Orientation. The transform value goes straight into hl.monitor and hl.device
# with no second table, so an off-by-one here puts every touch at right angles
# to the finger.
# ---------------------------------------------------------------------------

report "orientation" < <($PY - "$ROOT/scripts/orientation" 2>"$TMP/py.err" <<'PYEOF'
import contextlib, importlib.machinery, importlib.util, io, json, os, sys, tempfile

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

ld = importlib.machinery.SourceFileLoader("ori", sys.argv[1])
o = importlib.util.module_from_spec(importlib.util.spec_from_loader("ori", ld))
ld.exec_module(o)

# Hyprland's transform enum, verbatim. Not an arbitrary mapping: hl.monitor
# reads these numbers.
chk("orientation: transform table is Hyprland's enum",
    o.TRANSFORM == {"normal": 0, "90": 1, "180": 2, "270": 3}, repr(o.TRANSFORM))

G = 9.8
for vec, want in (([0, -G, 0], "normal"), ([0, G, 0], "180"),
                  ([-G, 0, 0], "270"), ([G, 0, 0], "90")):
    got, conf, flat = o.classify(vec)
    chk("orientation: gravity %s reads %s (transform %d)" % (vec, want, o.TRANSFORM[want]),
        got == want and not flat and conf > 0.99, repr((got, conf, flat)))

# Face up. The horizontal axes are noise here, and reporting an orientation
# from noise is how auto-rotate flips the screen while it sits on a table.
got, conf, flat = o.classify([0, 0, G])
chk("orientation: face up is flat, with no confidence", (got, conf, flat) == ("flat", 0.0, True),
    repr((got, conf, flat)))
got, conf, flat = o.classify([1.0, 1.0, G])
chk("orientation: a nearly flat reading is still flat (FLAT_THRESHOLD holds)", flat,
    repr((got, conf, flat)))

# 45 degrees: gravity sits exactly between two axes. It must land below the
# 0.82 default so `sure` is false and nothing rotates while the machine is
# being picked up.
got, conf, flat = o.classify([6.9, -6.9, 0])
chk("orientation: a 45 degree tilt is under the confidence floor",
    abs(conf - 0.707) < 0.01, repr((got, conf, flat)))

# --- the bogus first read ---------------------------------------------------
#
# The first read after the sensor has been idle returns exactly [0, 0, 1000]
# raw: a clean 1g on Z, physically plausible and completely wrong. Emitting it
# rotates the screen at every start. Driven through a temp sysfs tree rather
# than a subprocess because the script has no env override for SYSFS_IIO --
# adding one would make this testable end to end.
d = tempfile.mkdtemp()
dev = os.path.join(d, "iio:device0")
os.makedirs(dev)

def w(name, value):
    with open(os.path.join(dev, name), "w") as fh:
        fh.write(str(value))

w("name", "accel_3d")
w("in_accel_scale", "0.001")
w("in_accel_x_raw", 0); w("in_accel_y_raw", 0); w("in_accel_z_raw", 1000)  # the artifact
o.SYSFS_IIO = d
# The re-sample sleeps 0.25s; the sensor "settles" during that sleep.
o.time.sleep = lambda _s: (w("in_accel_x_raw", 0), w("in_accel_y_raw", -9800), w("in_accel_z_raw", 0))

buf = io.StringIO()
sys.argv = ["orientation"]
with contextlib.redirect_stdout(buf):
    rc = o.main()
got = json.loads(buf.getvalue())
chk("orientation: the idle artifact is discarded and re-sampled",
    rc == 0 and got["orientation"] == "normal" and got["flat"] is False, repr(got))
chk("orientation: a decisive reading is marked sure", got.get("sure") is True, repr(got))

# And the confidence floor is wired into `sure`, not just reported beside it.
w("in_accel_x_raw", 6900); w("in_accel_y_raw", -6900); w("in_accel_z_raw", 0)
o.time.sleep = lambda _s: None
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    o.main()
got = json.loads(buf.getvalue())
chk("orientation: a 45 degree reading is reported but not sure", got.get("sure") is False, repr(got))

for f in os.listdir(dev):
    os.unlink(os.path.join(dev, f))
os.rmdir(dev); os.rmdir(d)
print("__omatouch_block_complete__")
PYEOF
)

# On a machine with no accel_3d this is the only honest answer, and the plugin
# depends on it: exit 2 plus a JSON error, never a traceback.
if [[ -e /sys/bus/iio/devices ]] && grep -qsx accel_3d /sys/bus/iio/devices/iio:device*/name; then
  "$ROOT/scripts/orientation" >"$TMP/ori.json" 2>/dev/null
  check "orientation --once exits 0 with an accelerometer fitted" 0 $?
else
  "$ROOT/scripts/orientation" >"$TMP/ori.json" 2>/dev/null
  check "orientation exits 2 when there is no accel_3d" 2 $?
  if $PY -c 'import json,sys; sys.exit(0 if "error" in json.load(open(sys.argv[1])) else 1)' "$TMP/ori.json"; then
    ok "orientation says so as JSON, not as a traceback"
  else
    bad "orientation did not report the missing sensor as JSON: $(head -c 120 "$TMP/ori.json")"
  fi
fi

# ---------------------------------------------------------------------------
# clamshell: the plugin's ONLY privileged operation.
#
# A fake pkexec goes first on PATH and dumps its argv NUL-separated to a file.
# Nothing here reaches a real pkexec, so there is no password dialog stealing
# focus, no write to /etc and no logind reload. And nothing here ever turns
# clamshell ON for real -- a laptop that no longer suspends on a closed lid
# flattens itself in a bag.
# ---------------------------------------------------------------------------

mkdir -p "$TMP/shim"
cat >"$TMP/shim/pkexec" <<'SHIMEOF'
#!/usr/bin/env python3
import os, sys
with open(os.environ["PKEXEC_CANARY"], "wb") as fh:
    fh.write(b"\0".join(a.encode() for a in sys.argv[1:]))
SHIMEOF
chmod 755 "$TMP/shim/pkexec"

run_clamshell() { # canary action...
  local canary="$1"; shift
  rm -f "$canary"
  PKEXEC_CANARY="$canary" PATH="$TMP/shim:$PATH" "$ROOT/scripts/clamshell" "$@"
}

run_clamshell "$TMP/on.argv" on >"$TMP/on.json" 2>/dev/null
run_clamshell "$TMP/off.argv" off >"$TMP/off.json" 2>/dev/null

report "clamshell argv" < <($PY - "$TMP/on.argv" "$TMP/off.argv" 2>"$TMP/py.err" <<'PYEOF'
import os, re, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

def argv(path):
    if not os.path.exists(path):
        return None
    return open(path, "rb").read().decode().split("\0")

on, off = argv(sys.argv[1]), argv(sys.argv[2])
if on is None or off is None:
    print("bad clamshell on/off never invoked pkexec at all")
    print("__omatouch_block_complete__")
    raise SystemExit(0)

chk("clamshell on: pkexec is handed exactly bash -c <script>",
    on[:2] == ["bash", "-c"] and len(on) == 3, repr(on[:2] + ["..."]))

script = on[2]
lines = script.splitlines()
DROPIN = "/etc/systemd/logind.conf.d/30-omacar-clamshell.conf"

chk("clamshell on: the first line is the constant install+cat, nothing interpolated",
    lines[0] == "install -d -m 755 /etc/systemd/logind.conf.d && cat > %s <<'OMATOUCH_EOF'" % DROPIN,
    repr(lines[0]))

# THE ONE THAT MATTERS. The body contains backticks ("`ignore` keeps it
# awake"). The day the delimiter loses its single quotes those become command
# substitution, executed by root.
chk("clamshell on: the heredoc delimiter is quoted", "<<'OMATOUCH_EOF'" in script)
chk("clamshell on: the body really does contain a backtick, so quoting is load-bearing",
    "`" in script)
chk("clamshell on: the heredoc is terminated on its own line", "OMATOUCH_EOF" in lines)

# reload, never restart. `systemctl restart systemd-logind` tears down the
# login session it owns -- it took this desktop down once already.
chk("clamshell on: ends in `systemctl reload systemd-logind`",
    lines[-1] == "systemctl reload systemd-logind", repr(lines[-1]))
chk("clamshell on: the word restart appears nowhere in the root script",
    "restart" not in script)

chk("clamshell on: writes only inside /etc/systemd/logind.conf.d",
    re.match(r"^/etc/systemd/logind\.conf\.d/[A-Za-z0-9._-]+\.conf$", DROPIN) is not None
    and script.count(DROPIN) == 1)
chk("clamshell on: the policy written is HandleLidSwitch(ExternalPower)=ignore",
    "HandleLidSwitch=ignore" in script and "HandleLidSwitchExternalPower=ignore" in script)

chk("clamshell off: removes exactly that file and reloads",
    off[:2] == ["bash", "-c"]
    and off[2] == "rm -f %s && systemctl reload systemd-logind" % DROPIN,
    repr(off[2:]))
print("__omatouch_block_complete__")
PYEOF
)

# status is polled every 30 seconds from a Timer with triggeredOnStart. A
# privileged path in here would raise a polkit password dialog, stealing focus,
# twice a minute forever.
run_clamshell "$TMP/status.argv" status >"$TMP/status.json" 2>/dev/null
status_rc=$?
check "clamshell status exits 0" 0 "$status_rc"
if [[ -e "$TMP/status.argv" ]]; then
  bad "clamshell status invoked pkexec -- the 30s poll would prompt for a password"
else
  ok "clamshell status never invokes pkexec"
fi
if $PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(k in d for k in ("on_battery","on_ac","clamshell","lid","managed")) else 1)' "$TMP/status.json"; then
  # Not asserted: that on_ac is non-empty or that `clamshell` reflects the
  # effective policy. HandleLidSwitchExternalPower reads back as "" on a box
  # with no lid, and that is a truthful answer, not a bug.
  ok "clamshell status is JSON with on_battery/on_ac/clamshell/lid/managed"
else
  bad "clamshell status JSON is missing keys: $(head -c 160 "$TMP/status.json")"
fi

# argparse's choices= is the only thing between the caller and that root
# command string. If it is ever swapped for a free-form argument, the caller
# writes what root runs.
run_clamshell "$TMP/evil.argv" 'x; rm -rf /' >/dev/null 2>&1
check "clamshell rejects an unknown action with argparse's exit 2" 2 $?
if [[ -e "$TMP/evil.argv" ]]; then
  bad "a rejected action still reached pkexec"
else
  ok "a rejected action never reaches pkexec"
fi

# ---------------------------------------------------------------------------
# The manifest, and the QML the shell will compile.
# ---------------------------------------------------------------------------

VALIDATE=""
command -v omarchy >/dev/null 2>&1 && VALIDATE="omarchy plugin validate"
if [[ -z "$VALIDATE" ]]; then
  skip "manifest validation: the omarchy CLI is not on PATH"
else
  # The canonical validator, not a reimplementation: it mirrors the shell's own
  # PluginRegistry and additionally rejects symlinks and absolute/.. entry
  # points. A manifest the shell rejects is the failure where the plugin
  # installs, enables, and silently does nothing.
  if $VALIDATE "$ROOT" >"$TMP/validate.txt" 2>&1; then
    ok "manifest.json passes \`omarchy plugin validate\` (repo)"
  else
    bad "manifest.json fails \`omarchy plugin validate\`: $(head -3 "$TMP/validate.txt" | tr '\n' ' ')"
  fi
  INSTALLED="$HOME/.config/omarchy/plugins/prezziej.touchscreen"
  if [[ -d "$INSTALLED" ]]; then
    if $VALIDATE "$INSTALLED" >"$TMP/validate2.txt" 2>&1; then
      ok "the installed copy passes \`omarchy plugin validate\` too"
    else
      bad "the INSTALLED copy fails validation: $(head -3 "$TMP/validate2.txt" | tr '\n' ' ')"
    fi
  else
    skip "installed-copy validation: the plugin is not installed on this machine"
  fi
fi

report "manifest" < <($PY - "$ROOT" 2>"$TMP/py.err" <<'PYEOF'
import json, os, re, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

root = sys.argv[1]
mf = json.load(open(os.path.join(root, "manifest.json")))

chk("manifest: schemaVersion 1", mf.get("schemaVersion") == 1, repr(mf.get("schemaVersion")))
# A dropped "service" leaves the bar widget with a null service and no reader;
# a dropped "bar-widget" leaves the user with no way in at all.
chk("manifest: kinds declares both service and bar-widget",
    set(mf.get("kinds") or []) >= {"service", "bar-widget"}, repr(mf.get("kinds")))
eps = mf.get("entryPoints") or {}
chk("manifest: an entry point for each kind, and the file exists",
    all(eps.get(k) and os.path.isfile(os.path.join(root, eps[k]))
        for k in ("service", "barWidget")), repr(eps))

# Key-set drift between the manifest and Service.qml is a settings control that
# writes a key nothing reads, or a default the shell never learns about.
defaults = set(mf["barWidget"]["defaults"])
schema = {s["key"] for s in mf["barWidget"]["schema"]}
block = re.search(r"readonly property var defaults: \(\{(.*?)\n  \}\)",
                  open(os.path.join(root, "Service.qml")).read(), re.S).group(1)
block = re.sub(r"//.*", "", block)
service = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", block, re.M))
chk("manifest: barWidget.defaults and barWidget.schema cover the same keys",
    defaults == schema, "only in defaults %s, only in schema %s" % (defaults - schema, schema - defaults))
chk("manifest: those keys are exactly Service.qml's defaults",
    defaults == service, "only in manifest %s, only in Service.qml %s"
    % (defaults - service, service - defaults))
print("__omatouch_block_complete__")
PYEOF
)

QMLFORMAT=""
for c in /usr/lib/qt6/bin/qmlformat "$(command -v qmlformat 2>/dev/null)"; do
  [[ -n "$c" && -x "$c" ]] && { QMLFORMAT="$c"; break; }
done
if [[ -z "$QMLFORMAT" ]]; then
  skip "QML parse: qmlformat not installed"
else
  # A syntax error here does not fail an install; it fails at load, on the
  # shell's console, with the widget simply absent.
  qml_bad="" qml_n=0
  for f in "$ROOT"/*.qml; do
    ((qml_n++))
    "$QMLFORMAT" -n "$f" >/dev/null 2>&1 || qml_bad="$qml_bad $(basename "$f")"
  done
  # The count, because a glob over nothing loops zero times and reports success.
  # Five is the manifest's two entry points plus Overlay, Hud and Panel; a sixth
  # would be a new file nobody added to install.sh's explicit list.
  check "there are five QML files to parse" 5 "$qml_n"
  if [[ -z "$qml_bad" ]]; then
    ok "all five QML files parse ($(basename "$QMLFORMAT") -n)"
  else
    bad "QML files fail to parse:$qml_bad"
  fi
fi

# IpcHandler.target must be a string LITERAL. Quickshell's
# IpcHandler::updateRegistration does an unchecked dynamic_cast on that path;
# as a binding it re-evaluates on every hot reload and segfaults the whole
# shell -- 68 of 131 crash reports on the sibling plugin carry that signature.
# Every file save is a chance to fire it, so only a test keeps it true.
# Comment-stripped, because both files carry that warning in prose right above
# the line.
# The first `target:` in Service.qml belongs to a Connections block, not to the
# IpcHandler, so this has to open the right brace rather than take the first
# match in the file.
ipc_target() {
  qcode "$1" | awk '
    /IpcHandler[[:space:]]*\{/ { inside = 1 }
    inside && /^[[:space:]]*target:/ {
      sub(/^[[:space:]]*target:[[:space:]]*/, ""); sub(/[[:space:]]+$/, "")
      print; exit
    }'
}
svc_target="$(ipc_target "$ROOT/Service.qml")"
bar_target="$(ipc_target "$ROOT/BarWidget.qml")"
check "Service.qml IpcHandler.target is a literal" '"prezziej.touchscreen"' "$svc_target"
check "BarWidget.qml IpcHandler.target is a literal" '"prezziej.touchscreen.bar"' "$bar_target"

# ---------------------------------------------------------------------------
# The HUD's layer surface. It is mapped on every screen, always, at
# WlrLayer.Overlay. If it ever accepts input it swallows every touch AND every
# mouse click on the entire desktop, permanently, with no obvious cause.
#
# Source inspection, because the behavioural version -- mapping a full-screen
# overlay on the live desktop to prove it does not eat clicks -- is exactly the
# experiment you cannot run safely if the answer is no.
# ---------------------------------------------------------------------------

ov="$TMP/overlay.stripped"
qcode "$ROOT/Overlay.qml" >"$ov"
grep -qE '^\s*mask: Region \{\s*\}\s*$' "$ov" \
  && ok "Overlay: mask is an empty Region (input passes straight through)" \
  || bad "Overlay: mask is no longer an empty Region -- the HUD would swallow every touch on the desktop"
grep -qF 'exclusionMode: ExclusionMode.Ignore' "$ov" \
  && ok "Overlay: exclusionMode Ignore (reserves no space)" \
  || bad "Overlay: exclusionMode is no longer Ignore"
grep -qF 'WlrLayershell.keyboardFocus: WlrKeyboardFocus.None' "$ov" \
  && ok "Overlay: keyboardFocus None" \
  || bad "Overlay: keyboardFocus is no longer None"
ns="$(grep -oE 'WlrLayershell\.namespace: "[^"]*"' "$ov" | head -1 | sed -E 's/.*"([^"]*)"/\1/')"
check "Overlay: layer-surface namespace" "omatouch-hud" "$ns"

# Hyprland matches layer rules as substrings, so a namespace that a stock rule's
# name is a prefix of silently inherits that rule's blur and ignore_alpha.
# Checked against the rules actually loaded on this machine, not a list baked in
# here -- a new stock rule is exactly the change that would break it.
rule_files=()
for d in "$HOME/.config/hypr" "$HOME/.local/share/omarchy/default/hypr" \
         "$HOME/Work/omarchy/omarchy-installer/default/hypr"; do
  [[ -d "$d" ]] && while IFS= read -r f; do rule_files+=("$f"); done \
    < <(find "$d" -name '*.lua' ! -name '*.bak.*' -type f 2>/dev/null)
done
if ((${#rule_files[@]} == 0)); then
  skip "layer-rule namespace collision: no Hyprland lua config found"
else
  clash=""
  while IFS= read -r rns; do
    [[ -z "$rns" || "$rns" == "$ns" ]] && continue
    [[ "$ns" == *"$rns"* ]] && clash="$clash $rns"
  done < <(grep -ho 'layer_rule({[^}]*namespace = "[^"]*"' "${rule_files[@]}" 2>/dev/null \
           | grep -o 'namespace = "[^"]*"' | sed -E 's/.*"([^"]*)"/\1/' | sort -u)
  if [[ -z "$clash" ]]; then
    ok "no loaded layer rule's namespace is a substring of \"$ns\""
  else
    bad "layer rules would silently apply to the HUD:$clash"
  fi
fi

# ---------------------------------------------------------------------------
# The write path into Hyprland. A regression here takes the compositor down,
# not the plugin, so these are the guards that must not disappear.
# ---------------------------------------------------------------------------

svc="$TMP/service.stripped"
qcode "$ROOT/Service.qml" >"$svc"

# ~20 reloads a MINUTE before this guard. Each reload told xdg-desktop-portal
# the monitor layout had changed, which made every input-capture client rebuild
# its session; twenty minutes of that wedged the portal and Hyprland aborted
# inside CANRManager::runDialog.
grep -qF 'if (next === root.lastWritten) return' "$svc" \
  && ok "applyConfig: identical config is never rewritten (no reload storm)" \
  || bad "applyConfig lost its lastWritten guard -- this measured ~20 hyprctl reloads a minute"

# Setting running = true on a Process that is already running is silently
# dropped. The write that got dropped once left
# hl.device({ name = "at-translated-set-2-keyboard", enabled = false }) in place
# after tablet mode was switched OFF: a laptop with no keyboard.
grep -qF 'if (writer.running) { root.writePending = true; return }' "$svc" \
  && ok "applyConfig: a write during an in-flight write is queued, not dropped" \
  || bad "applyConfig lost its writePending coalescing -- a dropped re-enable leaves the keyboard disabled"
# SCOPED TO THE WRITER, and it has to be. This was two file-wide greps --
# `onExited: function(code, status) {` and `root.applyConfig()` -- and both
# match somewhere else: the lid Process has an identically-shaped onExited, and
# applyConfig() is called from eight places. Proved by mutation: deleting the
# replay out of writer.onExited entirely left this test green, which is the
# dropped write that leaves `enabled = false` on the keyboard.
#
# The extractor takes the `Process {` block that declares `id: writer` and
# stops at the first close-brace back at Scope-child indent. That rule is only
# safe because the block is emptiness-checked below -- a reindent that breaks
# the rule fails loudly instead of asserting nothing.
qml_block() { # file id
  qcode "$1" | awk -v want="  id: $2\$" '
    $0 ~ want { inside = 1 }
    inside { print }
    inside && /^  \}$/ { exit }'
}
wblock="$(qml_block "$ROOT/Service.qml" writer)"
if [[ -z "$wblock" || "$wblock" != *"onExited"* ]]; then
  bad "could not find the writer Process block in Service.qml -- this check is asserting nothing"
elif grep -qF 'root.applyConfig()' <<<"$wblock" && grep -qF 'root.writePending = false' <<<"$wblock"; then
  ok "writer.onExited replays the coalesced write"
else
  bad "writer.onExited no longer replays the coalesced write -- a dropped re-enable leaves the keyboard disabled"
fi

# The generated Lua is data on its way to disk and must not be expanded by the
# shell that carries it.
grep -qF "<<'OMATOUCH_EOF'" "$svc" \
  && ok "the generated Lua is written through a quoted heredoc" \
  || bad "the toggles heredoc delimiter is no longer quoted"

# A monitor block without scale resets a HiDPI panel to 1x and makes the
# desktop unreadable, which is why the live scale is read back and echoed.
grep -qF 'scale = " + Number(root.monitorScale).toFixed(6)' "$svc" \
  && ok "every generated hl.monitor block carries an explicit scale" \
  || bad "the generated hl.monitor block no longer echoes the live scale -- a HiDPI panel would drop to 1x"

# Nothing expensive for hardware you do not own: the reader, the accelerometer
# watcher and the lid poll are each gated on a touchscreen actually being here.
gated_ok=1
grep -qF 'running: root.present && root.value("hud") && root.active' "$svc" || gated_ok=0
grep -qF 'running: root.present && (root.value("autoRotate") || root.value("autoTabletMode"))' "$svc" || gated_ok=0
grep -qF 'running: root.present && root.value("disableWhenLidClosed")' "$svc" || gated_ok=0
((gated_ok)) \
  && ok "reader, orientation watcher and lid poll are all gated on root.present" \
  || bad "a Process lost its root.present gate -- machines with no touchscreen would pay for it"

# ---------------------------------------------------------------------------
# The live compositor. Everything here is a read; nothing reloads or writes.
# ---------------------------------------------------------------------------

if ! command -v hyprctl >/dev/null 2>&1 || ! hyprctl -j version >/dev/null 2>&1; then
  skip "hyprctl checks: no running Hyprland to ask"
else
  # Everything the plugin does flows through the names scraped out of these
  # sections, and applyConfig() returns immediately when that list is empty. A
  # renamed header means the plugin silently applies nothing at all, with no
  # error anywhere -- a compositor-version dependency only a live check catches.
  hyprctl devices >"$TMP/devices.txt" 2>/dev/null
  anchors="$(qcode "$ROOT/Service.qml" | grep -oE '/\^[A-Za-z]+:/' | tr -d '/^' | sort -u)"
  missing=""
  for a in $anchors; do
    grep -qE "^${a}\$" "$TMP/devices.txt" || missing="$missing $a"
  done
  if [[ -z "$anchors" ]]; then
    bad "Service.qml's awk programs no longer anchor on any ^Header: line"
  elif [[ -z "$missing" ]]; then
    ok "every section header Service.qml anchors on exists in \`hyprctl devices\` ($(echo $anchors | tr '\n' ' '))"
  else
    bad "\`hyprctl devices\` no longer has these headers Service.qml awks for:$missing"
  fi

  # Service.qml runs `hyprctl monitors -j | head -c 4000` and JSON.parse's the
  # result. One monitor is ~1.7KB here, so two fit and three do not: on a
  # three-display desk the parse fails silently, monitorName stays empty, the
  # hl.monitor block is never emitted and auto-rotate simply never rotates.
  if hyprctl monitors -j 2>/dev/null | head -c 4000 | $PY -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    mon_bytes=$(hyprctl monitors -j 2>/dev/null | wc -c)
    mon_count=$(hyprctl monitors -j 2>/dev/null | $PY -c 'import json,sys; print(len(json.load(sys.stdin)))')
    ok "hyprctl monitors -j still parses after the plugin's 4000-byte truncation (${mon_bytes}B for ${mon_count} monitor(s))"
  else
    bad "hyprctl monitors -j no longer parses truncated at 4000 bytes -- auto-rotate will silently never fire"
  fi

  # The HUD surface, if the plugin is actually loaded. Absence is not a failure
  # here: this box does not run the plugin.
  if hyprctl layers 2>/dev/null | grep -qF "namespace: $ns"; then
    layer_n=$(hyprctl layers 2>/dev/null | grep -cF "namespace: $ns")
    mon_count=$(hyprctl monitors -j 2>/dev/null | $PY -c 'import json,sys; print(len(json.load(sys.stdin)))')
    check "the HUD layer surface exists once per monitor" "$mon_count" "$layer_n"
  else
    skip "HUD layer surface: the plugin is not loaded in this shell"
  fi
fi

TOGGLES="$HOME/.local/state/omarchy/toggles/hypr/touchscreen.lua"
if [[ ! -f "$TOGGLES" ]]; then
  skip "generated Lua: $TOGGLES does not exist (the plugin has never run here)"
else
  # Invalid Lua makes Hyprland reject the whole toggles file, so none of the
  # settings apply. luac -p parses without executing anything.
  if command -v luac >/dev/null 2>&1; then
    luac -p "$TOGGLES" 2>"$TMP/luac.err" \
      && ok "the generated toggles file is valid Lua" \
      || bad "the generated toggles file is not valid Lua: $(head -1 "$TMP/luac.err")"
  else
    skip "generated Lua syntax: luac not installed"
  fi
  report "generated Lua" < <($PY - "$TOGGLES" 2>"$TMP/py.err" <<'PYEOF'
import re, sys

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

text = open(sys.argv[1]).read()
mon = re.search(r"hl\.monitor\(\{(.*?)\}\)", text, re.S)
if not mon:
    print("ok   (no hl.monitor block in the generated Lua -- nothing to cross-check)")
else:
    body = mon.group(1)
    chk("generated Lua: the hl.monitor block carries an explicit scale",
        "scale =" in body, repr(body[:120]))
    mt = re.search(r"transform = (\d+)", body)
    chk("generated Lua: the hl.monitor block carries a transform", mt is not None)
    if mt:
        dev = [int(m) for m in re.findall(r"hl\.device\(\{[^}]*?transform = (\d+)", text, re.S)]
        # A digitizer transform that disagrees with the display's is the exact
        # symptom this plugin exists to fix: touches at 90 degrees to the finger.
        chk("generated Lua: every device transform matches the monitor transform",
            all(d == int(mt.group(1)) for d in dev), "monitor %s, devices %s" % (mt.group(1), dev))
print("__omatouch_block_complete__")
PYEOF
)
  # The 10s probe, the 15s peripherals poll and the 30s clamshell poll all reach
  # applyConfig(); the file is rewritten only when the generated text differs,
  # so its mtime is a faithful proxy for reload count. Sixty seconds is the
  # shortest window that covers all three pollers, which is too slow for a
  # default run -- and the desk must be left alone while it runs.
  if [[ "${OMATOUCH_SLOW:-}" != "1" ]]; then
    skip "idle reload storm: needs a 60s quiet window (re-run with OMATOUCH_SLOW=1, and do not touch the settings)"
  else
    before=$(stat -c %Y "$TOGGLES")
    sleep 60
    check "an idle desktop rewrites the toggles file not at all" "$before" "$(stat -c %Y "$TOGGLES")"
  fi
fi

# No reader and no accelerometer watcher may be running when there is no
# touchscreen: each is gated on root.present, and dropping a guard would cost
# every Omarchy user without a touchscreen a 0.3s accelerometer poll forever.
#
# NEVER `pkill -f`, and not even `pgrep -f`: both match this suite's own
# command line, which on this machine is a documented way to kill your own
# session. This walks /proc/PID/cmdline and matches a whole argv ELEMENT --
# `ps | grep` would also match any editor or agent that merely has the path in
# its command line, because awk splits the blob a `bash -c` carries.
if [[ ! -d "$HOME/.config/omarchy/plugins/prezziej.touchscreen" ]]; then
  skip "idle-cost check: the plugin is not installed on this machine"
elif [[ "$present" == "yes" ]]; then
  skip "idle-cost check: a touchscreen IS fitted, so the reader is expected to run"
else
  report "idle-cost" < <($PY - 2>"$TMP/py.err" <<'PYEOF'
import os

def chk(name, cond, detail=""):
    print(("ok " + name) if cond else ("bad " + name + ((" -- " + detail) if detail else "")))

def running(suffix):
    me, hits = os.getpid(), []
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) == me:
            continue
        try:
            argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
        except OSError:
            continue
        if any(a.decode("utf-8", "replace").endswith(suffix) for a in argv if a):
            hits.append(pid)
    return hits

# Halves, joined at runtime: the whole string never appears in this process's
# own argv, so the check cannot find itself.
for what, suffix in (("touch-tap reader", "/scripts/touch" "-tap"),
                     ("orientation watcher", "/scripts/orient" "ation")):
    hits = running(suffix)
    chk("no %s running with no touchscreen fitted" % what, not hits, "pids %s" % hits)
print("__omatouch_block_complete__")
PYEOF
)
fi

# ---------------------------------------------------------------------------
# The installer. Run against a throwaway $HOME, because install.sh ends by
# calling `omarchy-shell shell rescanPlugins` -- the hot-reload path whose
# unchecked dynamic_cast is the crash signature this whole plugin is careful
# about. Firing it at the live shell six times per suite run is not a smoke
# test, it is a coin toss with the user's desktop.
#
# THE OLD COMMENT HERE CLAIMED "a PATH that cannot find omarchy-shell". It is
# not true and never was: /usr/bin/omarchy-shell exists on this machine, so
# `command -v` found it every run. What actually saved the desktop was second
# order -- `env -i` drops OMARCHY_PATH and omarchy-shell bails on the missing
# variable. That is an accident, not a guarantee, and it evaporates the day
# omarchy-shell grows a default. So the call is intercepted by a stub that goes
# first on PATH, and a canary proves the interception happened rather than
# assuming it did.
# ---------------------------------------------------------------------------

mkdir -p "$TMP/shim"
cat >"$TMP/shim/omarchy-shell" <<'OSEOF'
#!/usr/bin/env bash
# Records the call and refuses it, exactly as the real one does off-session.
printf '%s\n' "$*" >>"${OMARCHY_SHELL_CANARY:-/dev/null}"
echo "omarchy-shell is not running" >&2
exit 1
OSEOF
chmod 755 "$TMP/shim/omarchy-shell"
SANDBOX_PATH="$TMP/shim:/usr/bin:/bin"

FAKE="$TMP/home1"
mkdir -p "$FAKE"
env -i HOME="$FAKE" USER=smoketest PATH="$SANDBOX_PATH" \
  OMARCHY_SHELL_CANARY="$TMP/rescan.calls" \
  bash "$ROOT/install.sh" >"$TMP/install1.log" 2>&1
check "install.sh exits 0 against a sandbox HOME" 0 $?

# Both halves matter. That the stub was reached proves the real binary would
# have been -- the thing the old comment denied -- and that install.sh survives
# a refused rescan proves the `|| true` is still there, so a user running this
# from a TTY does not get a failed install over a shell that was never up.
if [[ -s "$TMP/rescan.calls" ]]; then
  ok "install.sh's rescanPlugins call is intercepted, never reaching the live shell"
else
  bad "install.sh no longer calls omarchy-shell -- if that is deliberate, drop the stub; if not, the live shell was just reloaded"
fi

PDIR="$FAKE/.config/omarchy/plugins/prezziej.touchscreen"
# LC_ALL=C: the default collation ignores the '/' and interleaves scripts/* with
# the top-level files, which makes the expected list unreadable.
got_files="$(cd "$PDIR" 2>/dev/null && find . -type f -printf '%P\n' | LC_ALL=C sort | tr '\n' ' ')"
want_files="BarWidget.qml Hud.qml Overlay.qml Panel.qml Service.qml manifest.json scripts/clamshell scripts/orientation scripts/touch-tap "
# An explicit list, not a glob: the shell compiles every .qml it finds in the
# plugin dir, so a lab or scratch file swept in would be compiled by the shell,
# and fixtures have no business shipping at all.
check "install.sh ships exactly the six plugin files and three scripts" "$want_files" "$got_files"

modes="$(stat -c '%a' "$PDIR"/scripts/* 2>/dev/null | sort -u | tr '\n' ' ')"
check "the installed scripts are mode 755" "755 " "$modes"

# The shell hot-reloads a plugin once per CHANGED FILE, and each reload is
# another roll of the dynamic_cast dice. A no-op re-run must therefore change
# nothing at all -- install.sh says so itself, and its scripts loop used to
# break the promise by calling `install` unconditionally.
find "$PDIR" -type f -printf '%T@ %m %P\n' | sort >"$TMP/before.txt"
sleep 1.1   # coarser than any filesystem's mtime granularity
env -i HOME="$FAKE" USER=smoketest PATH="$SANDBOX_PATH" bash "$ROOT/install.sh" >"$TMP/install2.log" 2>&1
find "$PDIR" -type f -printf '%T@ %m %P\n' | sort >"$TMP/after.txt"
if diff -q "$TMP/before.txt" "$TMP/after.txt" >/dev/null; then
  ok "a no-op re-run of install.sh rewrites nothing (no reload storm)"
else
  bad "install.sh rewrote files that had not changed:$(diff "$TMP/before.txt" "$TMP/after.txt" | grep '^>' | awk '{print " "$NF}' | tr -d '\n')"
fi

# A script that lands non-executable never runs, and identical content does not
# fix its own mode -- so the skip has to test both.
chmod 644 "$PDIR/scripts/clamshell"
env -i HOME="$FAKE" USER=smoketest PATH="$SANDBOX_PATH" bash "$ROOT/install.sh" >/dev/null 2>&1
check "install.sh repairs a script whose mode was broken" "755" "$(stat -c %a "$PDIR/scripts/clamshell")"

# Input-group detection, in all three states, with `id` shimmed. The third
# state is the interesting one: an installer for a bar widget that silently ran
# usermod would have made a privileged, durable change to the user's account,
# so a canary proves it never does.
cat >"$TMP/shim/id" <<'IDEOF'
#!/usr/bin/env bash
# install.sh calls `id -nG` for the session and `id -nG "$USER"` for the account.
if (($# >= 2)); then echo "$ACCOUNT_GROUPS"; else echo "$SESSION_GROUPS"; fi
IDEOF
cat >"$TMP/shim/usermod" <<'UMEOF'
#!/usr/bin/env bash
echo "$@" >>"$USERMOD_CANARY"
UMEOF
chmod 755 "$TMP/shim/id" "$TMP/shim/usermod"

group_case() { # label session-groups account-groups expected-substring
  local label="$1" sg="$2" ag="$3" want="$4"
  local h="$TMP/gh.$RANDOM" canary="$TMP/usermod.$RANDOM"
  mkdir -p "$h"
  local out
  out="$(env -i HOME="$h" USER=smoketest PATH="$SANDBOX_PATH" \
    SESSION_GROUPS="$sg" ACCOUNT_GROUPS="$ag" USERMOD_CANARY="$canary" \
    bash "$ROOT/install.sh" 2>&1)"
  if [[ "$out" == *"$want"* ]]; then
    ok "install.sh, $label: says \"$want\""
  else
    bad "install.sh, $label: expected \"$want\", got \"$(echo "$out" | grep -o 'input group:.*')\""
  fi
  if [[ -e "$canary" ]]; then
    bad "install.sh ran usermod ($label) -- it must never change the user's groups"
  else
    ok "install.sh, $label: never runs usermod"
  fi
  rm -rf "$h"
}
group_case "in the group now" "wheel input smoketest" "wheel input smoketest" \
  "this session can read /dev/input"
group_case "granted since login" "wheel smoketest" "wheel input smoketest" \
  "THIS session predates it"
group_case "not a member" "wheel smoketest" "wheel smoketest" \
  "not a member"

printf '\n'
if ((fails)); then echo "  $fails failure(s)."; exit 1; else echo "  All green."; fi
