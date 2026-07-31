#!/usr/bin/env python3
"""Add the frozen per-board designators and validate two-device BOM coverage.

Also cross-checks BOM.md's frozen-parts table against bom.csv (MPN, qty,
assembly side, LCSC citation) so the two documents cannot drift silently —
e.g. an LCSC code present in the csv but uncited in BOM.md, or a part listed
in one file only.
"""

import csv
import re
from pathlib import Path

PATH = Path(__file__).with_name("bom.csv")
BOM_MD = Path(__file__).with_name("BOM.md")

# BOM.md frozen-table "Function" label -> bom.csv "Function" value.
MD_TO_CSV = {
    "BLE/USB MCU": "MCU radio", "USB-C": "USB-C", "USB ESD": "USB data ESD",
    "VBUS TVS": "VBUS TVS", "Charger/power path": "Charger power path",
    "3.3 V regulator": "3V3 buck-boost", "5 V RGB boost": "5V RGB boost",
    "RGB load switch": "RGB load switch", "RGB buffer": "RGB level buffer",
    "Key RGB": "RGB LED", "Touch IC": "Touch", "Fuel gauge": "Fuel gauge",
    "Battery": "Protected LiPo", "Battery header": "Battery header",
    "Joystick": "Joystick", "Encoder": "Encoder", "Knob": "Encoder knob",
    "Hot-swap socket": "Hot-swap socket",
    "Tactile MX switch": "Tactile MX switch",
    "Frosted 1u cap": "Clear DSA 1u", "Ceramic 1u cap": "Ceramic 1u",
    "Reset/boot": "Reset boot", "SWD": "SWD",
}

REFS = {
    "MCU radio": "U1", "USB-C": "J1", "USB data ESD": "U2",
    "VBUS TVS": "D14", "Charger power path": "U3",
    "3V3 buck-boost": "U4", "5V RGB boost": "U5",
    "RGB load switch": "U6", "RGB level buffer": "U7",
    "RGB LED": "LED1-LED13", "Touch": "U8", "Fuel gauge": "U9",
    "Protected LiPo": "BT1 (off-board)", "Battery header": "J2",
    "Joystick": "JS1", "Encoder": "ENC1", "Encoder knob": "KNOB1",
    "Hot-swap socket": "HS1-HS13",
    "Tactile MX switch": "SW1-SW13 (removable)",
    "Clear DSA 1u": "KC1-KC12", "Ceramic 1u": "KC13",
    "Reset boot": "SW14-SW15", "SWD": "J3 (footprint only)",
    "3V3 inductor": "L1", "RGB inductor": "L2", "USB CC": "R1-R2",
    "USB data series DNP": "R3-R4", "BQ ISET": "R5", "BQ ILIM": "R6",
    "BQ ITERM": "R7", "BQ timer": "R8", "Boost FB top": "R9",
    "100k network": "R10-R13", "10k network": "R14-R17",
    "I2C pullups": "R18-R19", "RGB input and touch series": "R20-R21",
    "RGB data": "R22", "100nF bypass": "C1-C21",
    "Radio bulk 4.7uF": "C23", "BQ 4.7uF": "C24-C25",
    "BQ 1uF": "C26", "3V3 10uF": "C27-C29",
    "Boost input 10uF": "C30", "Boost output 22uF": "C31-C32",
    "Load switch CT": "C33", "Touch Cs": "C34",
    "Joystick SAADC series": "R23-R24", "FG_ALRT pullup": "R25",
    "Joystick SAADC shunt": "C35-C36", "USB CC ESD": "D15",
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

# Cross-check the BOM.md frozen-parts table against the csv.
by_function = {row["Function"]: row for row in rows}
md_rows = []
in_table = False
for line in BOM_MD.read_text().splitlines():
    if line.startswith("## "):
        in_table = line.strip() == "## Frozen parts"
        continue
    if not (in_table and line.startswith("|")):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if len(cells) >= 5 and cells[0] != "Function" and not set(cells[0]) <= set("-: "):
        md_rows.append(cells[:5])

md_functions = [cells[0] for cells in md_rows]
drift = sorted(set(md_functions) ^ set(MD_TO_CSV))
assert not drift, f"Frozen-table functions drifted from MD_TO_CSV map: {drift}"

for function, selection, qty, assembly, status in md_rows:
    row = by_function.get(MD_TO_CSV[function])
    assert row is not None, f"BOM.md {function!r} has no bom.csv line"
    for token in re.findall(r"`([^`]+)`", selection):
        assert token in row["MPN"] or row["MPN"] in token, (
            f"{function}: BOM.md selection {token!r} vs csv MPN {row['MPN']!r}")
    assert numeric_prefix(qty) == numeric_prefix(row["Qty_per_unit"]), (
        f"{function}: BOM.md qty {qty!r} vs csv {row['Qty_per_unit']!r}")
    assert assembly == row["Assembly"], (
        f"{function}: BOM.md assembly {assembly!r} vs csv {row['Assembly']!r}")
    code = row["LCSC"]
    if code and code != "consign":
        assert code in status, (
            f"{function}: csv LCSC {code} is not cited in the BOM.md row")

with PATH.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fields + ["Designators"], lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)

print(f"Validated {len(rows)} complete BOM lines for two devices")
print(f"Cross-checked {len(md_rows)} frozen-table rows in BOM.md against bom.csv")
