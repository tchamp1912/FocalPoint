#!/usr/bin/env python3
"""Add the frozen per-board designators and validate two-device BOM coverage."""

import csv
import re
from pathlib import Path

PATH = Path(__file__).with_name("bom.csv")

REFS = {
    "MCU radio": "U1", "USB-C": "J1", "USB data ESD": "U2",
    "VBUS TVS": "D14", "Charger power path": "U3",
    "3V3 buck-boost": "U4", "5V RGB boost": "U5",
    "RGB load switch": "U6", "RGB level buffer": "U7",
    "RGB LED": "LED1-LED13", "Touch": "U8", "Fuel gauge": "U9",
    "Protected LiPo": "BT1 (off-board)", "Battery header": "J2",
    "Joystick": "JS1", "Encoder": "ENC1", "Encoder knob": "KNOB1",
    "Hot-swap socket": "HS1-HS13", "Matrix diode": "D1-D13",
    "Tactile MX switch": "SW1-SW13 (removable)",
    "Clear DSA 1u": "KC1-KC12", "Ceramic 1u": "KC13",
    "Reset boot": "SW14-SW15", "SWD": "J3 (footprint only)",
    "3V3 inductor": "L1", "RGB inductor": "L2", "USB CC": "R1-R2",
    "USB data series DNP": "R3-R4", "BQ ISET": "R5", "BQ ILIM": "R6",
    "BQ ITERM": "R7", "BQ timer": "R8", "Boost FB top": "R9",
    "100k network": "R10-R13", "10k network": "R14-R17",
    "I2C pullups": "R18-R19", "RGB input and touch series": "R20-R21",
    "RGB data": "R22", "100nF bypass": "C1-C22",
    "Radio bulk 4.7uF": "C23", "BQ 4.7uF": "C24-C25",
    "BQ 1uF": "C26", "3V3 10uF": "C27-C29",
    "Boost input 10uF": "C30", "Boost output 22uF": "C31-C32",
    "Load switch CT": "C33", "Touch Cs": "C34",
    "Insert": "INS1-INS4", "Screw": "SCR1-SCR4",
    "Silicone sheet": "FOOT1", "Transfer adhesive": "ADH1",
    "Bare PCB": "PCB1", "Top enclosure": "TOP1",
    "Bottom enclosure": "BOTTOM1", "Circular base": "BASE1",
    "Programming cable": "TOOL1", "Debugger development kit": "TOOL2",
}


def numeric_prefix(value):
    token = value.strip().split()[0]
    return int(token) if token.isdigit() else None


with PATH.open(newline="") as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    fields = [x for x in reader.fieldnames if x != "Designators"]

functions = {row["Function"] for row in rows}
missing = sorted(functions - REFS.keys())
extra = sorted(REFS.keys() - functions)
assert not missing, f"Missing designators: {missing}"
assert not extra, f"Stale designators: {extra}"

seen_refs = set()

for row in rows:
    row["Designators"] = REFS[row["Function"]]
    per = numeric_prefix(row["Qty_per_unit"])
    buy = numeric_prefix(row["Two_device_buy_qty"])
    bulk_unit = any(word in row["Two_device_buy_qty"] for word in ("pack", "footprint", "sheet", "roll"))
    if per and buy is not None and not bulk_unit:
        assert buy >= 2 * per, (row["Function"], per, buy)
    assert row["Manufacturer"] and row["MPN"], row["Function"]
    assert row["Validation"] not in {"", "OPEN"}, row["Function"]
    assert "TBD" not in str(row), row["Function"]
    if per:
        match = re.match(r"([A-Z-]+)(\d+)(?:-([A-Z-]+)?(\d+))?", row["Designators"])
        assert match, (row["Function"], row["Designators"])
        prefix, start, end_prefix, end = match.groups()
        start = int(start); end = int(end or start)
        assert not end_prefix or end_prefix == prefix, row["Designators"]
        expanded = {f"{prefix}{number}" for number in range(start, end + 1)}
        assert len(expanded) == per, (row["Function"], per, row["Designators"])
        assert not seen_refs.intersection(expanded), (row["Function"], seen_refs.intersection(expanded))
        seen_refs.update(expanded)

with PATH.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields + ["Designators"], lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)

print(f"Validated {len(rows)} complete BOM lines for two devices")
