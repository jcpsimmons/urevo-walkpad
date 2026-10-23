# urevo-walkpad

Control a Urevo Spacewalk 5L walking pad (BLE name `URTM054`) from a Mac. The pad speaks standard
Bluetooth FTMS with no vendor unlock.

## Pieces

- **Walkpad.app** (`app/main.swift`, SwiftUI + CoreBluetooth). Opening it connects, starts the belt if
  stopped and applies the preset (default incline 9, 2.5 mph). The window has speed and incline
  −/+ (arrow keys when focused: ↑↓ speed, ←→ incline, ⌘. stop), live stats, start/pause/stop
  and a preset menu. Closing the window quits and releases the pad.
- **Local API**: while the app runs it answers `GET http://127.0.0.1:47827/<command>[?v=<n>]` with JSON
  (loopback only). Commands: `status up down speed incline incline-up incline-down preset
  save-preset start pause stop`.
- **`walkpad` CLI** (bash + curl, linked to `~/.local/bin/walkpad`): `walkpad` opens the app without
  stealing focus and waits for the preset; other subcommands map to the API. Needs no Bluetooth
  permission, so any agent shell can use it.
- **Agent skill**: `~/.skills/walkpad/SKILL.md` (personal-skills repo), linked into Claude, Codex,
  Grok, Cursor, OpenCode and Gemini. Maps "notch it up/down" etc. to the CLI.
- `probe.py`: read-only GATT dump plus live notifications, for protocol work
  (`uv run --with bleak python probe.py`, from a terminal with Bluetooth permission).

Build and install: `./build.sh` (swiftc, ad-hoc signed, installs to `~/Applications`). macOS asks for
Bluetooth permission on first launch. The pad takes one connection at a time, so quit the phone app.

## Protocol notes (firmware V90.08.15)

- FTMS service `0x1826`. Feature `0x2ACC` = `5c160000 03000000`: speed and incline targets supported.
- Speed range `0x2AD4`: 0.96-6.43 km/h, step 0.16 km/h (0.6-4.0 mph in 0.1 mph steps).
  Incline range `0x2AD5`: 0-9.0%, step 1.0.
- Control point `0x2AD9`: `00` request control, `02 <u16 0.01 km/h>` target speed,
  `03 <s16 0.1%>` target incline, `07` start, `08 01` stop, `08 02` pause.
- Speed quirk: the firmware truncates the target to 0.1 km/h, converts to mph, and truncates to
  0.1 mph. Sending 3.20 km/h gives 1.9 mph, so the app rounds up to the next 0.1 km/h.
- Treadmill Data `0x2ACD` sets reserved flag bit 13 and appends a 24-bit value that climbs with
  each stride; it is treated as a step count (inferred).
- Also present but unused: vendor services `fff0`, `fee0`, `5833ff01-...` (probably what the Urevo app uses).
