# urevo-walkpad

Control a Urevo Spacewalk 5L walking pad (BLE name `URTM054`) from a Mac. The pad speaks standard
Bluetooth FTMS with no vendor unlock, so this talks to the Fitness Machine Control Point directly.

```
./walkpad.py status          # live mph / miles / time / steps / kcal
./walkpad.py speed 2.5       # mph, clamped to 0.6-4.0
./walkpad.py faster [0.1]
./walkpad.py slower [0.1]
./walkpad.py start | stop | pause
```

- Needs `uv`. Run it from a terminal app that has Bluetooth permission (macOS aborts with exit 134 otherwise).
- The pad takes one connection at a time: quit the phone app first.
- `probe.py` dumps the GATT table and live notifications (read-only). `ctl_test.py` was the first control test.

## Protocol notes (firmware V90.08.15)

- FTMS service `0x1826`. Feature `0x2ACC` = `5c160000 03000000`: speed and incline targets supported.
- Speed range `0x2AD4`: 0.96-6.43 km/h, step 0.16 km/h (0.6-4.0 mph in 0.1 mph steps).
- Control point `0x2AD9`: `00` request control, `02 <u16 0.01 km/h>` target speed, `07` start, `08 01` stop, `08 02` pause.
- Speed quirk: the firmware truncates the target to 0.1 km/h, converts to mph, and truncates to 0.1 mph.
  Sending 3.20 km/h gives 1.9 mph, so the CLI rounds up to the next 0.1 km/h.
- Treadmill Data `0x2ACD` sets reserved flag bit 13 and appends a 24-bit value that climbs with
  each stride; the CLI treats it as a step count (inferred).
- Also present but unused: vendor services `fff0`, `fee0`, `5833ff01-...` (probably what the Urevo app uses).
