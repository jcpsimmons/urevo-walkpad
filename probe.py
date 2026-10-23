"""Find the walking pad and dump its GATT table. Read-only: never writes."""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

FTMS = "00001826-0000-1000-8000-00805f9b34fb"
HINTS = ("urevo", "spacewalk", "ur-", "urtm", "walk", "treadmill", "tm")


def looks_like_pad(d, adv):
    name = (d.name or adv.local_name or "").lower()
    return FTMS in adv.service_uuids or any(h in name for h in HINTS)


async def main():
    target = sys.argv[1] if len(sys.argv) > 1 else None
    found = await BleakScanner.discover(timeout=15, return_adv=True)
    rows = sorted(found.values(), key=lambda x: -x[1].rssi)
    for d, adv in rows:
        flag = "  <== candidate" if looks_like_pad(d, adv) else ""
        print(adv.rssi, d.address, d.name or adv.local_name, adv.service_uuids, flag)
    if target is None:
        cands = [d for d, adv in rows if looks_like_pad(d, adv)]
        if not cands:
            print("\nNo candidate found. Re-run with an address: python probe.py <address>")
            return
        target = cands[0].address
    print(f"\n=== Connecting to {target} ===")
    async with BleakClient(target, timeout=20) as c:
        notifiable = []
        for s in c.services:
            print(f"\n[service] {s.uuid}  {s.description}")
            for ch in s.characteristics:
                print(f"  [char] {ch.uuid}  {ch.description}  {ch.properties}")
                if "read" in ch.properties:
                    try:
                        v = await c.read_gatt_char(ch)
                        print(f"         read: {v.hex()}  {v!r}")
                    except Exception as e:
                        print(f"         read failed: {e}")
                if "notify" in ch.properties or "indicate" in ch.properties:
                    notifiable.append(ch)

        def cb(ch):
            return lambda _, data: print(f"  notify {ch.uuid[4:8]}: {data.hex()}")

        for ch in notifiable:
            try:
                await c.start_notify(ch, cb(ch))
            except Exception as e:
                print(f"  subscribe {ch.uuid} failed: {e}")
        print("\n=== Listening to notifications for 15 s ===")
        await asyncio.sleep(15)


asyncio.run(main())
