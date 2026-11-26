#!/usr/bin/env python3
"""Regenerates the expected-refusal table in OEMGoldenFixtureTests.swift.

Independent of the Swift decoder on purpose: it re-implements just enough of OBDb's
format (ISO-TP reassembly, `bix`/`len`/`blsb`/`sign`, `mul`/`div`/`add`, `min`/`max`,
`map`) to recompute every expected value in OEMGoldenFixtures.json, checks that each one
reproduces OBDb's recorded value (OBDb clamps to [min, max]), and prints the readings whose
unclamped value lies outside the signal's range. Those are the values the production
decoder must refuse as out of range, and nothing else.

Usage (from the package root):
    python3 -I Tests/SwiftOBD2Tests/Fixtures/OEM/golden_refusals.py Tests/SwiftOBD2Tests/Fixtures/OEM
Paste the printed Swift lines into `expectedRefusals`. It exits non-zero if any recomputed
value disagrees with OBDb's, so a table is never printed from a misread fixture.
"""

import json
import sys


def reassemble(lines, extended):
    """One ISO-TP message from one responder's frames. BMW extended addressing carries the
    tester address (F1) before the PCI byte."""
    message, total = None, None
    for line in lines:
        frame = bytes.fromhex(line[3:])
        if extended:
            frame = frame[1:]
        kind = frame[0] >> 4
        if kind == 0:
            return frame[1 : 1 + (frame[0] & 0x0F)]
        if kind == 1:
            total = ((frame[0] & 0x0F) << 8) | frame[1]
            message = bytearray(frame[2:])
        elif kind == 2:
            message += frame[1:]
    return bytes(message[:total])


def raw_bits(payload, bix, length, lsb_first):
    """Bits [bix, bix + len) counted from the most significant bit of the first payload byte;
    `blsb` reads the (byte-aligned) bytes least significant first."""
    if lsb_first:
        assert bix % 8 == 0 and length % 8 == 0, (bix, length)
        segment = payload[bix // 8 : bix // 8 + length // 8]
        assert len(segment) * 8 == length, "reply too short"
        return int.from_bytes(segment, "little")
    assert (bix + length + 7) // 8 <= len(payload), "reply too short"
    whole = int.from_bytes(payload, "big")
    return (whole >> (len(payload) * 8 - bix - length)) & ((1 << length) - 1)


def main(directory):
    fixtures = json.load(open(directory + "/OEMGoldenFixtures.json"))
    catalog = json.load(open(directory + "/OEMCatalog.json"))
    disagreements, checked, refusals = 0, 0, []
    for vehicle in fixtures["vehicles"]:
        entry = next(v for v in catalog["vehicles"] if v["id"] == vehicle["id"])
        modules = {m["id"]: m for m in entry["modules"]}
        for index, case in enumerate(vehicle["cases"]):
            command = next(c for c in entry["commands"] if c["id"] == case["command"])
            extended = modules[command["module"]]["target"]["kind"] == "bmwExtended"
            message = reassemble(case["response"], extended)
            assert message[0] == 0x62 and message[1:3].hex().upper() == command["did"], case
            payload = message[3:]
            for signal_id, want in case["expected"].items():
                checked += 1
                fmt = next(s for s in command["signals"] if s["id"] == signal_id)["fmt"]
                raw = raw_bits(payload, fmt.get("bix", 0), fmt["len"], fmt.get("blsb", False))
                if fmt.get("sign") and raw >= 1 << (fmt["len"] - 1):
                    raw -= 1 << fmt["len"]
                if "map" in fmt:
                    got = fmt["map"].get(str(raw))
                    if not (got == want or (isinstance(got, dict) and got.get("value") == want)):
                        disagreements += 1
                        print(f"disagree: {vehicle['id']} case {index} {signal_id}", file=sys.stderr)
                    continue
                value = raw * fmt.get("mul", 1) / fmt.get("div", 1) + fmt.get("add", 0)
                if value in (fmt.get("nullmin"), fmt.get("nullmax")):
                    print(f"note: {vehicle['id']} case {index} {signal_id} is a null sentinel", file=sys.stderr)
                low, high = fmt.get("min", 0), fmt.get("max")
                ranged = high is not None and high > low
                clamped = max(low, min(value, high)) if ranged else value
                if abs(clamped - want) > 1e-5:
                    disagreements += 1
                    print(f"disagree: {vehicle['id']} case {index} {signal_id}: {clamped} vs {want}", file=sys.stderr)
                if ranged and clamped != value:
                    refusals.append((vehicle["id"], index, case["command"], signal_id, raw, value, low, high))
    print(f"// {checked} expected values, {disagreements} disagreements, {len(refusals)} outside [min, max]", file=sys.stderr)
    if disagreements:
        sys.exit(1)
    for vehicle_id, index, command, signal_id, raw, value, low, high in refusals:
        print(
            f'        .init(vehicle: "{vehicle_id}", caseIndex: {index}, command: "{command}", '
            f'signal: "{signal_id}", raw: {raw}, value: {value!r}, minimum: {low!r}, maximum: {high!r}),'
        )


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
