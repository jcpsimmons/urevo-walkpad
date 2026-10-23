"""FTMS control test: request control, bump speed 2.0 -> 2.1 mph, then back to 2.0."""
import asyncio
import struct

from bleak import BleakClient, BleakScanner

CP = "00002ad9-0000-1000-8000-00805f9b34fb"
STATUS = "00002ada-0000-1000-8000-00805f9b34fb"
DATA = "00002acd-0000-1000-8000-00805f9b34fb"
RESULTS = {1: "success", 2: "not supported", 3: "invalid param", 4: "failed", 5: "control not permitted"}


def speed_cmd(kmh):
    return bytes([0x02]) + struct.pack("<H", round(kmh * 100))


async def main():
    dev = await BleakScanner.find_device_by_name("URTM054", timeout=15)
    if dev is None:
        print("URTM054 not found (phone still connected?)")
        return
    async with BleakClient(dev, timeout=20) as c:
        await c.start_notify(CP, lambda _, d: print(f"  CP reply: op 0x{d[1]:02x} -> {RESULTS.get(d[2], d[2])}  ({d.hex()})"))
        await c.start_notify(STATUS, lambda _, d: print(f"  status: {d.hex()}"))
        await c.start_notify(DATA, lambda _, d: print(f"  speed now {struct.unpack_from('<H', d, 2)[0] / 100 / 1.609344:.2f} mph"))

        print("request control")
        await c.write_gatt_char(CP, b"\x00", response=True)
        await asyncio.sleep(2)
        print("set 2.1 mph (3.36 km/h)")
        await c.write_gatt_char(CP, speed_cmd(3.36), response=True)
        await asyncio.sleep(6)
        print("set 2.0 mph (3.20 km/h)")
        await c.write_gatt_char(CP, speed_cmd(3.20), response=True)
        await asyncio.sleep(5)


asyncio.run(main())
