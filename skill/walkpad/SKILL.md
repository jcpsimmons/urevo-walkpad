---
name: walkpad
description: Control a Urevo walking pad (treadmill) from this Mac with the `walkpad` command. Use when the user says "notch it up", "notch it down", "faster", "slower", "speed up", "slow down", "incline up/down", "max incline", "start my walk", "go to my preset", "pause/stop the treadmill", "how far have I walked", or mentions the walking pad, walkpad or treadmill.
---

# Walkpad

`walkpad` (on PATH at `~/.local/bin/walkpad`) talks to the Walkpad app over
`http://127.0.0.1:47827`. The app owns the Bluetooth link, so any agent shell
can run these commands without Bluetooth permission. Source:
https://github.com/jcpsimmons/urevo-walkpad

## Phrase to command

| User says | Run |
|---|---|
| "notch it up", "faster", "speed up" | `walkpad up` (+0.1 mph; "a couple notches" = `walkpad up 0.2`) |
| "notch it down", "slower", "slow down" | `walkpad down` (-0.1 mph) |
| "set it to 2.8" | `walkpad speed 2.8` |
| "incline up" / "incline down" | `walkpad incline-up` / `walkpad incline-down` (1% steps) |
| "max incline", "flat" | `walkpad incline 9` / `walkpad incline 0` |
| "start my walk", "fire up the treadmill" | `walkpad` (opens the app; it starts the belt and applies the preset) |
| "back to my preset" | `walkpad preset` |
| "save this as my preset" | `walkpad save-preset` |
| "pause" / "stop" | `walkpad pause` / `walkpad stop` |
| "how am I doing", "how far" | `walkpad status` |
| "I'm done", "close it" | `walkpad stop`, then `walkpad quit` |

"Notch" means speed unless the user says incline. Several notches at once: pass the
total step, e.g. three notches up = `walkpad up 0.3`.

## Output

Every command prints JSON: `ok`, `msg` and `status` (`mph`, `incline`,
`target_mph`, `target_incline`, `miles`, `elapsed`, `steps`, `kcal`, preset
values). `mph` is the live belt reading and lags the target for a second or two
while the belt ramps; report the target. Reply in one short line, e.g.
"2.6 mph, incline 9." Exit code 1 means the command failed; say why from `msg`.

## Rules

- The user is usually walking on it. Only run `walkpad` (open), `start` or `preset`
  when they ask to start walking; they move the belt.
- Stop or pause only when asked.
- If a command says the app is not running, ask before opening it, unless they
  asked to start walking.
- Limits: 0.6-4.0 mph in 0.1 steps, incline 0-9% in 1% steps. Values outside are clamped.
- Only one Bluetooth connection at a time: the Urevo phone app can't connect while
  Walkpad is open. `walkpad quit` releases the pad.

## Heart-rate control (local development)

- `walkpad monitor` opens without starting the belt or applying a preset. Use this for HeartCast setup.
- `walkpad heart` reads current BPM, freshness, and a proposed speed adjustment. It never moves the belt.
- `walkpad zone-on` enables automatic speed adjustment only on explicit request. It requires a running belt,
  incline 9%, speed at or below 3.0 mph, and at least 25 seconds of fresh heart-rate samples.
- `walkpad zone-off` disables automation without changing belt speed.
- Approach 144 BPM, settle within 142-146, then hold throughout 139-149 BPM.
- Correct only after the average remains outside 139-149 for 30 seconds, then approach the center again.
- Speed ceiling: 3.0 mph. Adjustments: 0.1 mph, at least 45 seconds apart; reversals wait 120 seconds.
- Automation turns off on manual app/API commands, lost HR, stale treadmill data, stopped belt,
  or changed incline. It does not restart automatically, stop the belt on signal loss, or lower incline.
- Do not claim live readings or automatic control are tested until actual device data confirms them.
