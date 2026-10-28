# urevo-walkpad

Control a Urevo walking pad from your Mac: a small floating window, a `walkpad`
command, and an agent skill so you can tell Claude (or Codex, Grok, whatever you
run) to "notch it up" while you walk.

I have a Urevo Spacewalk 5L under my desk and the iPhone app sucks. It turns out
the pad speaks standard Bluetooth FTMS (the Fitness Machine Service that Zwift
and Kinomap use) with no vendor handshake, so a Mac can drive it directly. No
reverse engineering of the app was needed.

## What you get

- **Walkpad.app.** Open it and it finds the pad, starts the belt if it is
  stopped, and goes to your preset (out of the box: incline 9, 2.5 mph). The
  window shows speed and incline with big - / + buttons, plus miles, time,
  steps and calories. Close the window and the app quits and lets go of the pad.
- **`walkpad` CLI.** `walkpad up`, `walkpad incline-down`, `walkpad status`
  and friends. It talks to the running app over a loopback-only HTTP port, so it
  needs no Bluetooth permission of its own.
- **Agent skill** in `skill/walkpad/SKILL.md`. It maps phrases like "notch it
  down", "max incline" and "how far have I walked" to the CLI, and tells the agent
  not to start or stop the belt unless you ask.

## Requirements

- macOS 14 or later.
- Xcode or the Xcode command line tools (`xcode-select --install`) for `swiftc`.
- A Urevo walking pad that advertises as `URTM...` over Bluetooth. Tested on the
  Spacewalk 5L (`URTM054`, firmware V90.08.15). Other Urevo models that support
  Zwift or Kinomap probably work, since that means FTMS. I have only tried mine.

## Install

```bash
git clone https://github.com/jcpsimmons/urevo-walkpad.git
cd urevo-walkpad
./build.sh
```

`build.sh` compiles the app, signs it ad hoc, copies it to
`~/Applications/Walkpad.app`, and links the CLI to `~/.local/bin/walkpad`. Make
sure `~/.local/bin` is on your `PATH`.

First launch:

1. Force-quit the Urevo phone app or turn off your phone's Bluetooth. The pad
   accepts one connection at a time and stops advertising while the phone holds it.
2. Turn the pad on and stand on it. Opening the app starts the belt.
3. Run `walkpad` (or open Walkpad from Spotlight).
4. macOS asks whether Walkpad may use Bluetooth. Allow it.

## Use it

The window:

| Control | Does |
|---|---|
| - / + next to speed, or ↓ / ↑ | 0.1 mph down / up |
| - / + next to incline, or ← / → | 1% down / up |
| Start, Pause, Stop (⌘. stops) | what they say |
| Preset menu | go to the preset, or save the current speed and incline as the new preset |
| pin icon | keep the window on top (on by default) |

Arrow keys only act while the Walkpad window has focus. `walkpad` opens the
window without stealing focus, so typing elsewhere won't change your speed.

The CLI (the app must be running; plain `walkpad` starts it):

```
walkpad                      open the app, start the belt, apply the preset
walkpad status               current reading as JSON
walkpad up [0.1]             notch speed up (mph)
walkpad down [0.1]           notch speed down
walkpad speed 2.8            set speed
walkpad incline-up [1]       notch incline up (%)
walkpad incline-down [1]     notch incline down
walkpad incline 9            set incline
walkpad preset               back to the saved preset
walkpad save-preset          save current speed + incline as the preset
walkpad start | pause | stop
walkpad quit                 close the app and release the pad
```

Every command prints JSON with `ok`, `msg` and a `status` object (`mph`,
`incline`, `target_mph`, `target_incline`, `miles`, `elapsed`, `steps`, `kcal`).
Under the hood it's `curl http://127.0.0.1:47827/<command>`, so anything that can
make a local HTTP request can drive the pad.

## Agent skill

Copy or link `skill/walkpad` into your agent's skills folder:

```bash
ln -s "$PWD/skill/walkpad" ~/.claude/skills/walkpad     # Claude Code
ln -s "$PWD/skill/walkpad" ~/.agents/skills/walkpad     # Codex and other agents that read ~/.agents
```

Then, mid-walk: "notch it up", "two notches down", "flatten it out", "how far
have I gone".

Agents running inside some apps (the Claude desktop app, for one) get killed by
macOS the moment they touch Bluetooth. That's why the app owns the Bluetooth
connection and everything else goes through the local port.

## Heart-rate mode (development)

The local development build can receive HeartCast heart rate over Bluetooth and
preview speed adjustments for a 139-149 BPM target. The controller requires
incline 9% and caps speed at 3.0 mph. This target is a configured preference,
not a universal definition of Zone 2. HeartCast reception and an automatic speed increase have been verified on the pad.
The center-seeking policy below has simulation coverage; live validation is pending.

1. Open HeartCast on iPhone and Watch and start its workout on the Watch.
2. Run `walkpad monitor` to open Walkpad without starting the belt or applying a preset.
3. Run `walkpad heart` to check BPM, sample age, and the proposed adjustment.
4. Once walking at incline 9% and no more than 3.0 mph, `walkpad zone-on` enables control.
5. Use `walkpad zone-off` to disable control while leaving speed unchanged.

The controller collects roughly 30 seconds of readings and approaches 144 BPM,
using 142-146 BPM as its settling band. Once settled, it holds speed anywhere
within 139-149 BPM. A correction requires the average to stay outside that
outer range for 30 seconds continuously; returning inside resets that timer.
After a correction it approaches the center again.

Changes are 0.1 mph, at least 45 seconds apart. Reversing the last adjustment's
direction requires 120 seconds since that adjustment. This allows movement
within the target range without continually changing speed at its edges.
Manual app/API controls cancel automation.
Heart-rate loss lasting over 15 seconds, invalid readings, or treadmill data
older than 5 seconds also disable it. The belt keeps its last speed; automation
never restarts itself. At minimum speed with heart rate above the target, the
app asks you to pause or lower incline manually. Maintaining maximum incline
cannot guarantee the target heart rate is achievable.

Preview mode sends no control commands. Normal launch still applies the saved
preset. The agent skill includes the new commands. Policy and packet-decoding
tests run without a treadmill:

```bash
swiftc -swift-version 5 app/HeartRate.swift tests/ZonePolicyTests.swift -o /tmp/walkpad-zone-tests
/tmp/walkpad-zone-tests
```

## Limits and known issues

- Speed is 0.6-4.0 mph in 0.1 steps, incline 0-9% in 1% steps. Out-of-range values are clamped.
- You can't change speed while the belt is stopped. Start it or use the preset first.
- Start, pause and stop are implemented per the FTMS spec but I haven't tested them on the pad yet.
- The Urevo phone app can't connect while Walkpad is open. Quit Walkpad to hand the pad back.

## Protocol notes

From probing the Spacewalk 5L (firmware V90.08.15). `probe.py` dumps the GATT
table and live notifications without writing anything:
`uv run --with bleak python probe.py`, from a terminal that has Bluetooth permission.

- FTMS service `0x1826`. Feature `0x2ACC` = `5c160000 03000000`, so speed and incline targets are supported.
- Speed range `0x2AD4`: 0.96-6.43 km/h, step 0.16 km/h (0.6-4.0 mph in 0.1 mph steps).
  Incline range `0x2AD5`: 0-9.0%, step 1.0.
- Control point `0x2AD9`: `00` request control, `02 <u16, 0.01 km/h>` target speed,
  `03 <s16, 0.1%>` target incline, `07` start, `08 01` stop, `08 02` pause.
- Speed quirk: the firmware truncates the target to 0.1 km/h, converts to mph, then truncates to
  0.1 mph. Send 3.20 km/h (1.99 mph) and you get 1.9. The app rounds up to the next 0.1 km/h.
- Treadmill Data `0x2ACD` sets reserved flag bit 13 and appends a 24-bit counter that climbs with
  each stride. The app treats it as a step count; that's an inference, not documented anywhere.
- The pad also exposes vendor services `fff0`, `fee0` and `5833ff01-...`, probably what the
  official app uses. Nothing here needs them.

## License

MIT
