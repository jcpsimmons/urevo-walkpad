#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bleak>=0.22"]
# ///
"""Control a Urevo walking pad (URTM054 / Spacewalk 5L) over Bluetooth FTMS.

  walkpad status            live readout until Ctrl-C
  walkpad speed 2.5         set speed in mph
  walkpad faster [0.1]      bump speed up (mph)
  walkpad slower [0.1]      bump speed down (mph)
  walkpad start | stop | pause

Only one Bluetooth connection at a time: close the phone app first.
"""
import argparse
import asyncio
import math
import struct
import sys

from bleak import BleakClient, BleakScanner

NAME = "URTM054"
CP = "00002ad9-0000-1000-8000-00805f9b34fb"
DATA = "00002acd-0000-1000-8000-00805f9b34fb"
SPEED_RANGE = "00002ad4-0000-1000-8000-00805f9b34fb"
KMH_PER_MPH = 1.609344
RESULTS = {1: "ok", 2: "not supported", 3: "invalid parameter", 4: "failed", 5: "control not permitted"}


def parse_treadmill_data(d):
    """Decode an FTMS Treadmill Data notification (0x2ACD)."""
    flags = struct.unpack_from("<H", d, 0)[0]
    i, out = 2, {}

    def take(fmt):
        nonlocal i
        v = struct.unpack_from(fmt, d, i)
        i += struct.calcsize(fmt)
        return v

    def u24():
        nonlocal i
        v = int.from_bytes(d[i:i + 3], "little")
        i += 3
        return v

    if not flags & 0x0001:
        out["speed_kmh"] = take("<H")[0] / 100
    if flags & 0x0002:
        out["avg_speed_kmh"] = take("<H")[0] / 100
    if flags & 0x0004:
        out["distance_m"] = u24()
    if flags & 0x0008:
        incline, _ramp = take("<hh")
        out["incline_pct"] = incline / 10
    if flags & 0x0010:
        take("<HH")
    if flags & 0x0020:
        take("<B")
    if flags & 0x0040:
        take("<B")
    if flags & 0x0080:
        out["kcal"], _, _ = take("<HHB")
    if flags & 0x0100:
        out["heart_rate"] = take("<B")[0]
    if flags & 0x0200:
        take("<B")
    if flags & 0x0400:
        out["elapsed_s"] = take("<H")[0]
    if flags & 0x0800:
        out["remaining_s"] = take("<H")[0]
    if flags & 0x1000:
        take("<hh")
    # Bit 13 is reserved in the FTMS spec; this firmware puts a 24-bit step count there.
    if flags & 0x2000 and len(d) >= i + 3:
        out["steps"] = u24()
    return out


def mph_to_kmh(mph):
    # The firmware truncates the target to 0.1 km/h, converts to mph, then truncates to
    # 0.1 mph. Round up to the next 0.1 km/h so the result lands on the requested mph.
    return math.ceil(round(mph * KMH_PER_MPH * 10, 6)) / 10


class Pad:
    def __init__(self, client):
        self.c = client
        self.replies = asyncio.Queue()
        self.latest = {}

    @classmethod
    async def connect(cls):
        dev = await BleakScanner.find_device_by_name(NAME, timeout=15)
        if dev is None:
            sys.exit(f"{NAME} not found. Is it on, and is the phone app disconnected?")
        client = BleakClient(dev, timeout=20)
        await client.connect()
        pad = cls(client)
        await client.start_notify(CP, lambda _, d: pad.replies.put_nowait(bytes(d)))
        await client.start_notify(DATA, pad._on_data)
        return pad

    def _on_data(self, _, d):
        self.latest = parse_treadmill_data(bytes(d))

    async def command(self, payload):
        await self.c.write_gatt_char(CP, payload, response=True)
        reply = await asyncio.wait_for(self.replies.get(), 5)
        if reply[0] != 0x80 or reply[2] != 1:
            raise RuntimeError(f"pad refused 0x{payload[0]:02x}: {RESULTS.get(reply[2], reply.hex())}")

    async def take_control(self):
        await self.command(b"\x00")

    async def wait_for_data(self):
        for _ in range(50):
            if self.latest:
                return self.latest
            await asyncio.sleep(0.1)
        raise RuntimeError("no treadmill data received")

    async def speed_limits_mph(self):
        lo, hi, _step = struct.unpack("<HHH", await self.c.read_gatt_char(SPEED_RANGE))
        return lo / 100 / KMH_PER_MPH, hi / 100 / KMH_PER_MPH

    async def set_speed_mph(self, mph):
        lo, hi = await self.speed_limits_mph()
        mph = round(min(max(mph, lo), hi), 1)
        await self.command(b"\x02" + struct.pack("<H", round(mph_to_kmh(mph) * 100)))
        return mph


def fmt(s):
    mph = s.get("speed_kmh", 0) / KMH_PER_MPH
    miles = s.get("distance_m", 0) / 1609.344
    m, sec = divmod(s.get("elapsed_s", 0), 60)
    return (f"{mph:4.1f} mph | {miles:5.2f} mi | {m:02d}:{sec:02d} | "
            f"{s.get('steps', 0):5d} steps | {s.get('kcal', 0):4d} kcal")


async def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("speed").add_argument("mph", type=float)
    for name in ("faster", "slower"):
        sub.add_parser(name).add_argument("step", type=float, nargs="?", default=0.1)
    for name in ("start", "stop", "pause"):
        sub.add_parser(name)
    args = p.parse_args()

    pad = await Pad.connect()
    try:
        if args.cmd == "status":
            while True:
                print("\r" + fmt(await pad.wait_for_data()), end="", flush=True)
                await asyncio.sleep(1)
        await pad.take_control()
        if args.cmd == "speed":
            print(f"speed -> {await pad.set_speed_mph(args.mph):.1f} mph")
        elif args.cmd in ("faster", "slower"):
            now = (await pad.wait_for_data())["speed_kmh"] / KMH_PER_MPH
            delta = args.step if args.cmd == "faster" else -args.step
            print(f"speed {now:.1f} -> {await pad.set_speed_mph(now + delta):.1f} mph")
        elif args.cmd == "start":
            await pad.command(b"\x07")
            print("started")
        elif args.cmd == "stop":
            await pad.command(b"\x08\x01")
            print("stopped")
        elif args.cmd == "pause":
            await pad.command(b"\x08\x02")
            print("paused")
        await asyncio.sleep(1.5)
        if pad.latest:
            print(fmt(pad.latest))
    finally:
        # CoreBluetooth can stall on disconnect after Ctrl-C; the OS drops the link anyway.
        try:
            await asyncio.wait_for(pad.c.disconnect(), 3)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            pass


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print()
