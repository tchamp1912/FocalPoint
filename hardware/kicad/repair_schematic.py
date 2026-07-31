#!/usr/bin/env python3
"""One-shot repair of the generated Rev A KiCad schematic.

The original capture used deliberately simplified local symbols.  This script
performs the reviewed, mechanical migration to real package pin numbers,
inserts the post-capture BOM circuits, and assigns verified footprints.  It is
kept in-tree so the transformation is auditable and repeatable.
"""

from __future__ import annotations

import re
import sys
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SCH = ROOT / "focalpoint.kicad_sch"
SYM = ROOT / "focalpoint.kicad_sym"
PROJECT_UUID = "58cd5175-207e-4724-8c44-e24ead61a60c"


def uid() -> str:
    return str(uuid.uuid4())


def balanced(text: str, start: int) -> tuple[int, str]:
    depth = 0
    quoted = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if quoted:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
            continue
        if ch == '"':
            quoted = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1, text[start : i + 1]
    raise ValueError(f"unbalanced expression at {start}")


def replace_named_lib_symbol(text: str, name: str, transform) -> str:
    marker = f'(symbol "focalpoint:{name}"'
    start = text.index(marker)
    end, block = balanced(text, start)
    return text[:start] + transform(block) + text[end:]


def replace_external_symbol(text: str, name: str, transform) -> str:
    marker = f'(symbol "focalpoint:{name}"'
    start = text.index(marker)
    end, block = balanced(text, start)
    return text[:start] + transform(block) + text[end:]


def remap_pin_numbers(block: str, mapping: dict[str, str]) -> str:
    pos = 0
    out = []
    while True:
        match = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not match:
            out.append(block[pos:])
            break
        start = pos + match.start()
        end, pin = balanced(block, start)
        name_match = re.search(r'\(name "([^"]+)"', pin)
        if name_match and name_match.group(1) in mapping:
            pin = re.sub(
                r'\(number "[^"]+"',
                f'(number "{mapping[name_match.group(1)]}"',
                pin,
                count=1,
            )
        out.extend((block[pos:start], pin))
        pos = end
    return "".join(out)


def set_pin_type(block: str, pin_name: str, pin_type: str) -> str:
    pos = 0
    while True:
        match = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not match:
            raise ValueError(f"pin {pin_name} not found")
        start = pos + match.start(); end, pin = balanced(block, start)
        name_match = re.search(r'\(name "([^"]+)"', pin)
        if name_match and name_match.group(1) == pin_name:
            pin = re.sub(r'^\(pin\s+[^()\s]+', f'(pin {pin_type}', pin, count=1)
            return block[:start] + pin + block[end:]
        pos = end


def stacked_pin(block: str, anchor_name: str, pin_type: str,
                name: str, number: str) -> str:
    """Add a physical pin at an existing logical pin's connected location."""
    if re.search(rf'\(number "{re.escape(number)}"', block):
        return block
    pos = 0
    while True:
        match = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not match:
            raise ValueError(f"anchor pin {anchor_name} not found")
        start = pos + match.start()
        end, pin = balanced(block, start)
        pin_name = re.search(r'\(name "([^"]+)"', pin)
        if pin_name and pin_name.group(1) == anchor_name:
            at = re.search(r'\(at [^)]+\)', pin).group(0)
            length = re.search(r'\(length [^)]+\)', pin).group(0)
            addition = f'''
\t\t\t\t(pin {pin_type} line {at} {length}
\t\t\t\t\t(name "{name}" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "{number}" (effects (font (size 1.27 1.27)))))
'''
            return insert_in_graphic_unit(block, addition)
        pos = end


def remove_pin_numbers(block: str, numbers: set[str]) -> str:
    spans = []
    pos = 0
    while True:
        match = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not match:
            break
        start = pos + match.start(); end, pin = balanced(block, start)
        number = re.search(r'\(number "([^"]+)"', pin)
        if number and number.group(1) in numbers:
            spans.append((start, end))
        pos = end
    for start, end in reversed(spans):
        block = block[:start] + block[end:]
    return block


def insert_in_graphic_unit(block: str, addition: str) -> str:
    embedded = block.rfind("(embedded_fonts no)")
    unit_close = block.rfind("\n\t\t\t)", 0, embedded)
    if unit_close < 0:
        raise ValueError("graphic unit terminator not found")
    return block[:unit_close] + addition + block[unit_close:]


U1_PINS = {
    "KEY1": "47", "KEY2": "61", "KEY3": "50", "KEY4": "60",
    "KEY5": "56", "KEY6": "59", "KEY7": "57", "KEY8": "58",
    "KEY9": "25", "KEY10": "26", "KEY11": "3", "KEY12": "4",
    "KEY13": "5", "JOY_X_AIN0": "11", "JOY_Y_AIN1": "9",
    "JOY_SW": "38", "ENC_A": "41", "ENC_B": "42", "ENC_SW": "44",
    "TOUCH_OUT": "39", "RGB_DATA": "22", "RGB_PWR_EN": "24",
    # BOOST_EN is a slow digital control.  Use the otherwise-unused P1.13 on
    # physical pad 6; pad 27/P0.11 is trapped in the staggered side-pad field
    # and cannot escape at the selected non-HDI fabrication rules.
    "BOOST_EN": "6", "CHG_STAT": "29", "PGOOD": "36",
    # Move the two I2C lines to well-separated module-edge GPIOs and place the
    # alert on unused P0.24/pad 48 on the opposite accessible edge.
    "FG_SDA": "8", "FG_SCL": "14", "FG_ALRT": "48",
    "DFU_P013": "37", "USB_DP": "35",
    "USB_DN": "34", "SWDIO": "51", "SWDCLK": "53",
    "nRESET_P018": "40", "VDD": "28", "GND": "1",
}

# Physical supply pads which are not represented by the original simplified
# logical symbol.  Raytac Ver. L identifies pads 1, 2, 15, 33 and 55 as GND,
# and pad 32 as the USB VBUS input/detect pin.  All five grounds must share the
# schematic GND connection; VBUS is a separate input.
U1_EXTRA_POWER_PINS = ["2", "15", "32", "33", "55"]
U1_ALL_PINS = list(U1_PINS.values()) + U1_EXTRA_POWER_PINS


def add_u1_power_pins(block: str) -> str:
    """Add the omitted MDBT50Q ground pads and USB VBUS pad."""
    if re.search(r'\(number "32"', block):
        return block
    additions = """
\t\t\t\t(pin power_in line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "GND2" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "2" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "GND15" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "15" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "GND33" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "33" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "GND55" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "55" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at 22.86 -48.26 180) (length 2.54)
\t\t\t\t\t(name "VBUS" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "32" (effects (font (size 1.27 1.27)))))
"""
    return insert_in_graphic_unit(block, additions)

U3_PINS = {
    "IN": "13", "SYS": "10", "BAT": "2", "ISET": "16",
    "ILIM": "12", "ITERM": "15", "TMR": "14", "TS": "1",
    "nCHG": "9", "nPGOOD": "7", "EN1": "6", "EN2": "5",
    "VSS": "8", "VDPM": "4",
}

U4_PINS = {
    "VIN": "5", "L1": "4", "L2": "2", "VOUT": "1",
    "FB": "10", "EN": "6", "PS_SYNC": "7", "GND": "9",
}
U5_PINS = {"VIN": "3", "SW": "5", "VOUT": "6", "FB": "1", "EN": "2", "GND": "4"}
U6_PINS = {"VIN": "1", "VOUT": "6", "ON": "3", "QOD": "5", "CT": "4", "GND": "2"}
U7_PINS = {"VCC": "5", "IN": "2", "OE": "1", "OUT": "4", "GND": "3"}
U8_PINS = {"VDD": "5", "VSS": "2", "SNS1": "3", "SNS2": "4", "OUT": "1"}
U9_PINS = {"CELL_VDD": "3", "GND": "4", "SDA": "8", "SCL": "7", "ALRT": "5"}
ENC1_PINS = {"A": "A", "B": "B", "COMMON": "C", "SW1": "S1", "SW2": "S2"}


def repair_u4_physical(block: str) -> str:
    block = remap_pin_numbers(block, U4_PINS)
    block = stacked_pin(block, "VIN", "power_in", "VINA", "8")
    block = stacked_pin(block, "GND", "power_in", "PGND", "3")
    return stacked_pin(block, "GND", "power_in", "EP", "11")


def repair_u8_physical(block: str) -> str:
    block = remap_pin_numbers(block, U8_PINS)
    return stacked_pin(block, "VSS", "input", "SYNC_MODE", "6")


def repair_u9_physical(block: str) -> str:
    block = remap_pin_numbers(block, U9_PINS)
    block = stacked_pin(block, "CELL_VDD", "power_in", "CELL", "2")
    block = stacked_pin(block, "GND", "power_in", "CTG", "1")
    block = stacked_pin(block, "GND", "input", "QSTRT", "6")
    return stacked_pin(block, "GND", "power_in", "EP", "9")


def repair_j1_shield(block: str) -> str:
    return stacked_pin(block, "GND", "passive", "SHIELD", "SH")


def repair_u3(block: str) -> str:
    block = remove_pin_numbers(block, {"3", "11", "17"})
    block = remap_pin_numbers(block, U3_PINS)
    block = block.replace('(name "VDPM"', '(name "CE"')
    # Stacked duplicate power pads and exposed pad share the already-connected
    # BAT, OUT and VSS symbol locations.
    additions = """
\t\t\t\t(pin passive line (at -2.54 -7.62 0) (length 2.54)
\t\t\t\t\t(name "BAT" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "3" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_out line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "OUT" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "11" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at 17.78 -15.24 180) (length 2.54)
\t\t\t\t\t(name "EP" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "17" (effects (font (size 1.27 1.27)))))
"""
    return insert_in_graphic_unit(block, additions)


def repair_u2(block: str) -> str:
    # Retain the original three left-side graphical positions, but make them
    # the real DRT-3 shunt pads: D+, D-, GND. Remove fictional OUT/VBUS pins.
    pin_blocks = []
    pos = 0
    while True:
        m = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not m:
            break
        s = pos + m.start()
        e, p = balanced(block, s)
        name = re.search(r'\(name "([^"]+)"', p).group(1)
        if name in {"GND", "IO1", "IO2"}:
            pin_blocks.append((s, e, p, name))
        pos = e
    # Remove all six pins, then insert three accurate ones at the unit end.
    for s, e, _, _ in reversed(pin_blocks):
        pass
    all_pins = []
    pos = 0
    while True:
        m = re.search(r"\(pin\s+(?:[^()\s]+)\s+(?:[^()\s]+)", block[pos:])
        if not m:
            break
        s = pos + m.start(); e, p = balanced(block, s)
        all_pins.append((s, e)); pos = e
    for s, e in reversed(all_pins):
        block = block[:s] + block[e:]
    pins = """
\t\t\t\t(pin passive line (at -2.54 -2.54 0) (length 2.54)
\t\t\t\t\t(name "D+" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "1" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin passive line (at -2.54 -5.08 0) (length 2.54)
\t\t\t\t\t(name "D-" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "2" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at -2.54 -7.62 0) (length 2.54)
\t\t\t\t\t(name "GND" (effects (font (size 1.27 1.27))))
\t\t\t\t\t(number "3" (effects (font (size 1.27 1.27)))))
"""
    return insert_in_graphic_unit(block, pins)


def component_block(text: str, ref: str) -> tuple[int, int, str]:
    prop = text.index(f'(property "Reference" "{ref}"')
    start = text.rfind("\n\t(symbol\n", 0, prop) + 2
    end, block = balanced(text, start)
    return start, end, block


def replace_component_pin_list(text: str, ref: str, numbers: list[str]) -> str:
    start, end, block = component_block(text, ref)
    block = re.sub(r'\n\t\t\(pin "[^"]+" \(uuid "[^"]+"\)\)', "", block)
    marker = "\n\t\t(instances"
    pins = "".join(f'\n\t\t(pin "{n}" (uuid "{uid()}"))' for n in numbers)
    block = block.replace(marker, pins + marker, 1)
    return text[:start] + block + text[end:]


def add_u1_vbus_connection(text: str) -> str:
    """Connect the added U1 pad 32 symbol pin to the global VBUS net."""
    start, end, block = component_block(text, "U1")
    # The generated U1 block is followed by its pin wires.  A VBUS label in
    # this small neighborhood is the idempotence marker for this connection.
    if re.search(r'\(global_label "VBUS"', text[end : end + 1200]):
        return text
    at = re.search(r'\(at ([^ ]+) ([^ ]+) 0\)', block)
    if not at:
        raise ValueError("U1 placement not found")
    x, y = float(at.group(1)), float(at.group(2))
    pin_x, pin_y, label_x = x + 22.86, y + 48.26, x + 27.94
    addition = f'''
\t(wire (pts (xy {pin_x} {pin_y}) (xy {label_x} {pin_y}))
\t\t(stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "VBUS" (shape passive) (at {label_x} {pin_y} 0)
\t\t(effects (font (size 1.27 1.27)) (justify left)) (uuid "{uid()}")
\t\t(property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {label_x} {pin_y} 0)
\t\t\t(effects (font (size 1.27 1.27)) (hide yes))))
'''
    return text[:end] + addition + text[end:]


def set_footprint(block: str, footprint: str) -> str:
    return re.sub(
        r'(\(property "Footprint" )"[^"]*"',
        lambda m: m.group(1) + f'"{footprint}"', block, count=1,
    )


def assign_footprint(text: str, ref: str, footprint: str) -> str:
    start, end, block = component_block(text, ref)
    return text[:start] + set_footprint(block, footprint) + text[end:]


def two_pin(ref: str, value: str, lib: str, x: float, y: float,
            left: str, right: str, footprint: str) -> str:
    return f'''\n\t(symbol
\t\t(lib_id "focalpoint:{lib}")
\t\t(at {x} {y} 0) (unit 1) (exclude_from_sim no) (in_bom yes)
\t\t(on_board yes) (dnp no) (fields_autoplaced yes) (uuid "{uid()}")
\t\t(property "Reference" "{ref}" (at {x} {y-3.81} 0) (effects (font (size 1.27 1.27))))
\t\t(property "Value" "{value}" (at {x} {y-6.35} 0) (effects (font (size 1.27 1.27))))
\t\t(property "Footprint" "{footprint}" (at {x} {y} 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t(property "Datasheet" "" (at {x} {y} 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t(pin "1" (uuid "{uid()}")) (pin "2" (uuid "{uid()}"))
\t\t(instances (project "focalpoint" (path "/{PROJECT_UUID}" (reference "{ref}") (unit 1)))))
\t(wire (pts (xy {x-2.54} {y+2.54}) (xy {x-7.62} {y+2.54})) (stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "{left}" (shape passive) (at {x-7.62} {y+2.54} 180)
\t\t(effects (font (size 1.27 1.27)) (justify right)) (uuid "{uid()}")
\t\t(property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {x-7.62} {y+2.54} 0) (effects (font (size 1.27 1.27)) (hide yes))))
\t(wire (pts (xy {x+17.78} {y+2.54}) (xy {x+22.86} {y+2.54})) (stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "{right}" (shape passive) (at {x+22.86} {y+2.54} 0)
\t\t(effects (font (size 1.27 1.27)) (justify left)) (uuid "{uid()}")
\t\t(property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {x+22.86} {y+2.54} 0) (effects (font (size 1.27 1.27)) (hide yes))))
'''


def dual_tvs_lib() -> str:
    return '''
\t\t(symbol "focalpoint:D_TVS_DUAL_CA"
\t\t\t(exclude_from_sim no) (in_bom yes) (on_board yes)
\t\t\t(property "Reference" "D" (at 0 2.54 0) (effects (font (size 1.27 1.27))))
\t\t\t(property "Value" "D_TVS_DUAL_CA" (at 0 -10.16 0) (effects (font (size 1.27 1.27))))
\t\t\t(property "Footprint" "" (at 0 0 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t\t(property "Datasheet" "" (at 0 0 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t\t(symbol "D_TVS_DUAL_CA_1_1"
\t\t\t\t(rectangle (start 0 0) (end 15.24 -7.62) (stroke (width 0.254) (type default)) (fill (type background)))
\t\t\t\t(pin passive line (at -2.54 -2.54 0) (length 2.54) (name "K1" (effects (font (size 1.27 1.27)))) (number "1" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin passive line (at -2.54 -5.08 0) (length 2.54) (name "K2" (effects (font (size 1.27 1.27)))) (number "2" (effects (font (size 1.27 1.27)))))
\t\t\t\t(pin power_in line (at 17.78 -2.54 180) (length 2.54) (name "A" (effects (font (size 1.27 1.27)))) (number "3" (effects (font (size 1.27 1.27))))))
\t\t\t(embedded_fonts no))
'''


def dual_tvs_instance(x: float, y: float) -> str:
    return f'''\n\t(symbol (lib_id "focalpoint:D_TVS_DUAL_CA") (at {x} {y} 0) (unit 1)
\t\t(exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no) (fields_autoplaced yes) (uuid "{uid()}")
\t\t(property "Reference" "D15" (at {x} {y-3.81} 0) (effects (font (size 1.27 1.27))))
\t\t(property "Value" "PESD5V0U2BT,215" (at {x} {y-6.35} 0) (effects (font (size 1.27 1.27))))
\t\t(property "Footprint" "Package_TO_SOT_SMD:SOT-23" (at {x} {y} 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t(property "Datasheet" "" (at {x} {y} 0) (effects (font (size 1.27 1.27)) (hide yes)))
\t\t(pin "1" (uuid "{uid()}")) (pin "2" (uuid "{uid()}")) (pin "3" (uuid "{uid()}"))
\t\t(instances (project "focalpoint" (path "/{PROJECT_UUID}" (reference "D15") (unit 1)))))
\t(wire (pts (xy {x-2.54} {y+2.54}) (xy {x-7.62} {y+2.54})) (stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "USB_CC1" (shape passive) (at {x-7.62} {y+2.54} 180) (effects (font (size 1.27 1.27)) (justify right)) (uuid "{uid()}") (property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {x-7.62} {y+2.54} 0) (effects (font (size 1.27 1.27)) (hide yes))))
\t(wire (pts (xy {x-2.54} {y+5.08}) (xy {x-7.62} {y+5.08})) (stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "USB_CC2" (shape passive) (at {x-7.62} {y+5.08} 180) (effects (font (size 1.27 1.27)) (justify right)) (uuid "{uid()}") (property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {x-7.62} {y+5.08} 0) (effects (font (size 1.27 1.27)) (hide yes))))
\t(wire (pts (xy {x+17.78} {y+2.54}) (xy {x+22.86} {y+2.54})) (stroke (width 0) (type default)) (uuid "{uid()}"))
\t(global_label "GND" (shape passive) (at {x+22.86} {y+2.54} 0) (effects (font (size 1.27 1.27)) (justify left)) (uuid "{uid()}") (property "Intersheetrefs" "${{INTERSHEET_REFS}}" (at {x+22.86} {y+2.54} 0) (effects (font (size 1.27 1.27)) (hide yes))))
'''


def insert_before_sheet_instances(text: str, addition: str) -> str:
    marker = "\n\t(sheet_instances"
    return text.replace(marker, addition + marker, 1)


def rebuild_external_symbol_library(schematic: str) -> None:
    """Build a normal editable project library from the schematic cache."""
    start = schematic.index("\n\t(lib_symbols") + 2
    _, library_block = balanced(schematic, start)
    symbols = []
    pos = library_block.index("\n\t(symbol") + 2
    while True:
        marker = library_block.find("(symbol ", pos)
        if marker < 0:
            break
        # Cached library members are uniquely namespace-qualified. Match that
        # instead of indentation: the one-line D15 insertion is two tabs deep,
        # while nested graphics never carry the focalpoint namespace.
        if not library_block.startswith('(symbol "focalpoint:', marker):
            pos = marker + 8
            continue
        end, symbol = balanced(library_block, marker)
        symbol = re.sub(r'^\(symbol "focalpoint:', '(symbol "', symbol, count=1)
        # KiCad 10's standalone library schema has several fields that cached
        # schematic symbols omit. Preserve each symbol's embedded-fonts field
        # (it is per-symbol in a .kicad_sym), and add/normalize the required
        # position-file, duplicate-pin and property metadata.
        symbol = symbol.replace(
            "\n\t\t(on_board yes)",
            "\n\t\t(on_board yes)\n\t\t(in_pos_files yes)"
            "\n\t\t(duplicate_pin_numbers_are_jumpers no)",
            1,
        )
        prop_names = ("Reference", "Value", "Footprint", "Datasheet")
        for prop_name in prop_names:
            prop_start = symbol.index(f'(property "{prop_name}"')
            prop_end, prop = balanced(symbol, prop_start)
            prop = re.sub(
                r'(\n\s*\(at [^\n]+\))',
                r'\1\n\t\t\t(show_name no)\n\t\t\t(do_not_autoplace no)',
                prop,
                count=1,
            )
            prop = re.sub(
                r'\(effects \(font \(size ([^)]+)\)\) \(hide yes\)\)',
                r'(hide yes)\n\t\t\t(effects (font (size \1)))',
                prop,
            )
            symbol = symbol[:prop_start] + prop + symbol[prop_end:]
        datasheet_start = symbol.index('(property "Datasheet"')
        datasheet_end, _ = balanced(symbol, datasheet_start)
        description = '''
\t\t(property "Description" ""
\t\t\t(at 0 0 0)
\t\t\t(show_name no)
\t\t\t(do_not_autoplace no)
\t\t\t(hide yes)
\t\t\t(effects (font (size 1.27 1.27)))
\t\t)'''
        symbol = symbol[:datasheet_end] + description + symbol[datasheet_end:]
        symbols.append("\t" + symbol.replace("\n", "\n\t"))
        pos = end
    output = "(kicad_symbol_lib\n\t(version 20251024)\n\t(generator \"kicad_symbol_editor\")\n\t(generator_version \"10.0\")\n"
    output += "\n".join(symbols)
    output += "\n)\n"
    SYM.write_text("\n".join(line.rstrip() for line in output.splitlines()) + "\n")


def main() -> None:
    text = SCH.read_text()
    if 'property "Reference" "R23"' in text:
        raise SystemExit("schematic already repaired")

    text = replace_named_lib_symbol(
        text, "U1_MODULE", lambda b: add_u1_power_pins(remap_pin_numbers(b, U1_PINS))
    )
    text = replace_named_lib_symbol(text, "U2_ESD", repair_u2)
    text = replace_named_lib_symbol(text, "U3_CHARGER", repair_u3)

    # Instance pin lists follow the repaired physical package pad numbers.
    text = replace_component_pin_list(text, "U1", U1_ALL_PINS)
    text = replace_component_pin_list(text, "U2", ["1", "2", "3"])
    text = replace_component_pin_list(text, "U3", ["13", "10", "11", "2", "3", "16", "12", "15", "14", "1", "9", "7", "6", "5", "8", "17", "4"])
    text = add_u1_vbus_connection(text)

    # Scope net-label migrations to their component neighborhoods.
    u1s, _, _ = component_block(text, "U1")
    u2s, _, _ = component_block(text, "U2")
    u3s, _, _ = component_block(text, "U3")
    text = text[:u1s] + text[u1s:u2s].replace('"JOY_X"', '"JOY_X_FILT"').replace('"JOY_Y"', '"JOY_Y_FILT"').replace('"USB_DP"', '"USB_DP_ESD"').replace('"USB_DN"', '"USB_DN_ESD"') + text[u2s:]
    # Recalculate after changed lengths and remove fictional U2 output/VBUS
    # connection objects by changing their labels to the already-protected nets;
    # duplicate labels are harmless and preserve the generated sheet geometry.
    u2s, _, _ = component_block(text, "U2"); u3s, _, _ = component_block(text, "U3")
    region = text[u2s:u3s]
    region = region.replace('"USB_DP"', '"USB_DP_ESD"').replace('"USB_DN"', '"USB_DN_ESD"')
    region = region.replace('"VBUS"', '"GND"')
    text = text[:u2s] + region + text[u3s:]
    # Real CE is the former right-bottom graphical position and must be low.
    u3s, _, _ = component_block(text, "U3")
    c26s, _, _ = component_block(text, "C26")
    text = text[:u3s] + text[u3s:c26s].replace('"BQ_VDPM"', '"GND"') + text[c26s:]
    c26s, c26e, c26 = component_block(text, "C26")
    c26 = c26.replace('"BQ_VDPM"', '"VBUS"')
    text = text[:c26s] + c26 + text[c26e:]

    # Add the BOM-revision circuits in unused sheet space.
    additions = "".join([
        two_pin("R23", "1k", "R", 25.4, 558.8, "JOY_X", "JOY_X_FILT", "Resistor_SMD:R_0603_1608Metric"),
        two_pin("R24", "1k", "R", 76.2, 558.8, "JOY_Y", "JOY_Y_FILT", "Resistor_SMD:R_0603_1608Metric"),
        two_pin("C35", "10nF", "C", 127.0, 558.8, "JOY_X_FILT", "GND", "Capacitor_SMD:C_0603_1608Metric"),
        two_pin("C36", "10nF", "C", 177.8, 558.8, "JOY_Y_FILT", "GND", "Capacitor_SMD:C_0603_1608Metric"),
        two_pin("R25", "100k", "R", 228.6, 558.8, "+3V3", "FG_ALRT", "Resistor_SMD:R_0603_1608Metric"),
        dual_tvs_instance(279.4, 558.8),
    ])
    # Add the D15 cached library definition inside lib_symbols.
    ls = text.index("\n\t(lib_symbols") + 2
    le, lb = balanced(text, ls)
    lb = lb[:-1] + dual_tvs_lib() + "\t)"
    text = text[:ls] + lb + text[le:]
    text = insert_before_sheet_instances(text, additions)

    # Assign exact installed-library footprints, grouped by package family.
    fp: dict[str, str] = {
        "U1": "RF_Module:Raytac_MDBT50Q",
        "U2": "Package_TO_SOT_SMD:Texas_DRT-3",
        "U3": "Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm_ThermalVias",
        "U4": "Package_SON:WSON-10-1EP_2.5x2.5mm_P0.5mm_EP1.2x2mm_ThermalVias",
        "U5": "Package_TO_SOT_SMD:SOT-563",
        "U6": "Package_TO_SOT_SMD:SOT-23-6",
        "U7": "Package_TO_SOT_SMD:SOT-23-5",
        "U8": "Package_TO_SOT_SMD:SOT-23-6",
        "U9": "Package_DFN_QFN:TDFN-8-1EP_2x2mm_P0.5mm_EP0.8x1.2mm",
        "J1": "Connector_USB:USB_C_Receptacle_GCT_USB4105-xx-A_16P_TopMnt_Horizontal",
        "J2": "Connector_JST:JST_SH_SM02B-SRSS-TB_1x02-1MP_P1.00mm_Horizontal",
        "J3": "Connector:Tag-Connect_TC2030-IDC-NL_2x03_P1.27mm_Vertical",
        "ENC1": "Rotary_Encoder:RotaryEncoder_Alps_EC11E-Switch_Vertical_H20mm",
        "SW14": "Button_Switch_SMD:SW_SPST_B3U-1000P",
        "SW15": "Button_Switch_SMD:SW_SPST_B3U-1000P",
        "L1": "Inductor_SMD:L_Sunlord_SWPA3015S",
        "L2": "Inductor_SMD:L_Sunlord_MWSA0402S",
        "D14": "Diode_SMD:D_SOD-882",
        "D15": "Package_TO_SOT_SMD:SOT-23",
        "JS1": "FocalPoint:Alps_RKJXV122400R",
    }
    for n in range(1, 26): fp[f"R{n}"] = "Resistor_SMD:R_0603_1608Metric"
    for n in range(1, 37): fp[f"C{n}"] = "Capacitor_SMD:C_0603_1608Metric"
    for n in range(1, 14):
        fp[f"LED{n}"] = "LED_SMD:LED_SK6812MINI-E_3.2x2.8mm_P1.5mm_ReverseMount"
        fp[f"HS{n}"] = "FocalPoint:Kailh_CPG151101S11_Hotswap"
    for ref, footprint in fp.items():
        if f'(property "Reference" "{ref}"' in text:
            text = assign_footprint(text, ref, footprint)

    # BT1 is explicitly off-board and PWR_FLAGs are ERC constructs.
    for ref in ("BT1", "#FLG01", "#FLG02", "#FLG03"):
        if f'(property "Reference" "{ref}"' in text:
            s, e, b = component_block(text, ref)
            b = b.replace("(on_board yes)", "(on_board no)", 1)
            text = text[:s] + b + text[e:]

    SCH.write_text(text)

    # Keep the editable project library synchronized with the cached symbols.
    sym = SYM.read_text()
    sym = replace_external_symbol(
        sym, "U1_MODULE", lambda b: add_u1_power_pins(remap_pin_numbers(b, U1_PINS))
    )
    sym = replace_external_symbol(sym, "U2_ESD", repair_u2)
    sym = replace_external_symbol(sym, "U3_CHARGER", repair_u3)
    sym = sym[:-2] + dual_tvs_lib().replace('"focalpoint:D_TVS_DUAL_CA"', '"D_TVS_DUAL_CA"') + "\t(embedded_fonts no)\n)\n"
    SYM.write_text(sym)


def fixup_after_first_pass() -> None:
    """Correct first-pass naming assumptions without regenerating UUIDs."""
    text = SCH.read_text()
    text = replace_named_lib_symbol(
        text, "U1_MODULE", lambda b: add_u1_power_pins(remap_pin_numbers(b, U1_PINS))
    )
    text = replace_component_pin_list(text, "U1", U1_ALL_PINS)
    text = add_u1_vbus_connection(text)

    def u2_types(block: str) -> str:
        return set_pin_type(block, "GND", "passive")

    def u3_stacked_types(block: str) -> str:
        block = set_pin_type(block, "OUT", "passive")
        return block.replace('(name "EP"', '(name "VSS"')

    text = replace_named_lib_symbol(text, "U2_ESD", lambda b: u2_types(repair_u2(b)))
    text = replace_named_lib_symbol(text, "U3_CHARGER", lambda b: u3_stacked_types(repair_u3(b)))
    text = text.replace('"BQ_VDPM"', '"VBUS"')
    SCH.write_text(text)
    rebuild_external_symbol_library(text)


def fix_u1_power_after_review() -> None:
    """Apply the Raytac supply-pad correction to an already-repaired sheet."""
    text = SCH.read_text()
    _, _, u1 = component_block(text, "U1")
    already_fixed = '(pin "32"' in u1
    text = replace_named_lib_symbol(text, "U1_MODULE", add_u1_power_pins)
    text = replace_component_pin_list(text, "U1", U1_ALL_PINS)
    text = add_u1_vbus_connection(text)
    SCH.write_text(text)
    rebuild_external_symbol_library(text)
    print("U1 power pads already fixed" if already_fixed else "fixed U1 GND pads and VBUS detect")


def fix_package_pinouts_after_review() -> None:
    """Replace logical-order package pins with manufacturer physical pins."""
    text = SCH.read_text()
    transforms = {
        "U1_MODULE": lambda b: add_u1_power_pins(remap_pin_numbers(b, U1_PINS)),
        "U4_BUCKBOOST": repair_u4_physical,
        "U5_BOOST": lambda b: remap_pin_numbers(b, U5_PINS),
        "U6_LOADSW": lambda b: remap_pin_numbers(b, U6_PINS),
        "U7_BUFFER": lambda b: remap_pin_numbers(b, U7_PINS),
        "U8_TOUCH": repair_u8_physical,
        "U9_FUELGAUGE": repair_u9_physical,
        "ENC_EC11": lambda b: remap_pin_numbers(b, ENC1_PINS),
        "J_USBC": repair_j1_shield,
    }
    for name, transform in transforms.items():
        text = replace_named_lib_symbol(text, name, transform)

    pin_lists = {
        "U1": U1_ALL_PINS,
        "U4": [str(n) for n in range(1, 12)],
        "U5": [str(n) for n in range(1, 7)],
        "U6": [str(n) for n in range(1, 7)],
        "U7": [str(n) for n in range(1, 6)],
        "U8": [str(n) for n in range(1, 7)],
        "U9": [str(n) for n in range(1, 10)],
        "ENC1": ["A", "B", "C", "S1", "S2"],
        "J1": [
            "A1", "A4", "A5", "A6", "A7", "A8", "A9", "A12",
            "B1", "B4", "B5", "B6", "B7", "B8", "B9", "B12", "SH",
        ],
    }
    for ref, numbers in pin_lists.items():
        text = replace_component_pin_list(text, ref, numbers)

    # TPS61023 boost topology: the inductor is between SYS/VIN and SW.  The
    # earlier logical capture incorrectly placed it between SW and +5V.
    _, l2_end, _ = component_block(text, "L2")
    next_symbol = text.index("\n\t(symbol", l2_end)
    l2_connections = text[l2_end:next_symbol]
    l2_connections = l2_connections.replace(
        '(global_label "+5V"', '(global_label "SYS"', 1
    )
    text = text[:l2_end] + l2_connections + text[next_symbol:]

    SCH.write_text(text)
    rebuild_external_symbol_library(text)
    print("fixed physical pinouts for U4-U9, ENC1, and J1 shield")


if __name__ == "__main__":
    if "--fix-package-pinouts" in sys.argv:
        fix_package_pinouts_after_review()
    elif "--fix-u1-power" in sys.argv:
        fix_u1_power_after_review()
    elif "--fixup" in sys.argv:
        fixup_after_first_pass()
    else:
        main()
