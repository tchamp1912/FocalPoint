#!/usr/bin/env python3
"""Split the accepted flat FocalPoint schematic into functional child sheets.

The generated design deliberately retains the existing named global nets.  The
flat capture already uses one global label at every component pin, so moving a
complete symbol-and-label block between files preserves the electrical graph
without inventing new aliases.  The root sheet becomes a system-level index;
the three child sheets own all circuit symbols.
"""

from __future__ import annotations

import math
import re
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SCHEMATIC = ROOT / "focalpoint.kicad_sch"
FLAT_REFERENCE = ROOT / "focalpoint_flat_reference.kicad_sch"
SYMBOL_LIBRARY = ROOT / "focalpoint.kicad_sym"
SYMBOL_LIBRARY_REFERENCE = ROOT / "focalpoint_flat_reference.kicad_sym"
LAYOUT_REPORT = ROOT / "hierarchical_schematic_layout_validation.txt"

SHEETS = {
    "power": {
        "name": "Power Electronics",
        "file": "focalpoint_power.kicad_sch",
        "sheet_uuid": "f5ab84d8-f762-44cf-a7ae-ff4370829a01",
        "file_uuid": "05413334-0ff6-40b8-bb78-ae7a4e0b5ff5",
        "page": "2",
        "at": (35.56, 76.2),
        "size": (66.04, 38.1),
        "grid": (6, 8),
    },
    "signals": {
        "name": "Controller and Signals",
        "file": "focalpoint_signals.kicad_sch",
        "sheet_uuid": "f78606c3-9067-47e8-9188-d1545a31635f",
        "file_uuid": "ff5720ef-bc90-46f9-8972-7434ab4c1cf6",
        "page": "3",
        "at": (116.84, 76.2),
        "size": (66.04, 38.1),
        "grid": (4, 4),
    },
    "peripherals": {
        "name": "Inputs, RGB, and Peripherals",
        "file": "focalpoint_peripherals.kicad_sch",
        "sheet_uuid": "a13c1ead-b706-4cbb-83fe-980ae2e23a7d",
        "file_uuid": "64e03ec8-b9c5-486d-9d07-00fe93dfe210",
        "page": "4",
        "at": (198.12, 76.2),
        "size": (66.04, 38.1),
        "grid": (7, 8),
    },
}


POWER_REFS = {
    "BT1", "J2", "U3", "U4", "U5", "U6", "U9", "L1", "L2", "D14",
    "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12", "R14",
    "R15", "R16", "R18", "R19", "R25",
    "C14", "C15", "C16", "C17", "C18", "C19", "C21", "C23", "C24",
    "C25", "C26", "C27", "C28", "C29", "C30", "C31", "C32", "C33",
    "#FLG01", "#FLG06", "#FLG07",
}

SIGNAL_REFS = {
    "U1", "U2", "J1", "J3", "D15", "SW14", "SW15",
    "R1", "R2", "R3", "R4", "R17", "C20",
}

PERIPHERAL_REFS = {
    "ENC1", "JS1", "U7", "U8", "R13", "R20", "R21", "R22", "R23",
    "R24", "C34", "C35", "C36",
    *(f"HS{n}" for n in range(1, 14)),
    *(f"LED{n}" for n in range(1, 14)),
    *(f"C{n}" for n in range(1, 14)),
}

REFS_BY_SHEET = {
    "power": POWER_REFS,
    "signals": SIGNAL_REFS,
    "peripherals": PERIPHERAL_REFS,
}

NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
AT_RE = re.compile(rf"\(at\s+({NUMBER})\s+({NUMBER})(?=[\s)])")
XY_RE = re.compile(rf"\(xy\s+({NUMBER})\s+({NUMBER})\s*\)")

CONVENTIONAL_GRAPHICS = {
    "focalpoint:R": '''
			(polyline
				(pts (xy 0 -2.54) (xy 2.54 -2.54) (xy 3.81 -1.27)
					(xy 5.08 -3.81) (xy 6.35 -1.27) (xy 7.62 -3.81)
					(xy 8.89 -1.27) (xy 10.16 -3.81) (xy 11.43 -1.27)
					(xy 12.7 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)''',
    "focalpoint:C": '''
			(polyline
				(pts (xy 0 -2.54) (xy 6.35 -2.54))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)
			(polyline
				(pts (xy 8.89 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)
			(polyline
				(pts (xy 6.35 -5.08) (xy 6.35 0))
				(stroke (width 0.508) (type default))
				(fill (type none))
			)
			(polyline
				(pts (xy 8.89 -5.08) (xy 8.89 0))
				(stroke (width 0.508) (type default))
				(fill (type none))
			)''',
    "focalpoint:L": '''
			(polyline
				(pts (xy 0 -2.54) (xy 2.54 -2.54))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)
			(arc (start 2.54 -2.54) (mid 3.81 -1.27) (end 5.08 -2.54)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(arc (start 5.08 -2.54) (mid 6.35 -1.27) (end 7.62 -2.54)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(arc (start 7.62 -2.54) (mid 8.89 -1.27) (end 10.16 -2.54)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(arc (start 10.16 -2.54) (mid 11.43 -1.27) (end 12.7 -2.54)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 12.7 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)''',
    "focalpoint:D_TVS": '''
			(polyline
				(pts (xy 0 -2.54) (xy 5.08 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 5.08 -5.08) (xy 5.08 0) (xy 10.16 -2.54) (xy 5.08 -5.08))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 10.16 -5.08) (xy 10.16 -3.81) (xy 11.43 -2.54)
					(xy 10.16 -1.27) (xy 10.16 0))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 10.16 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))''',
    "focalpoint:SW2": '''
			(circle (center 3.81 -2.54) (radius 0.635)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(circle (center 11.43 -2.54) (radius 0.635)
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 0 -2.54) (xy 3.175 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 4.445 -2.54) (xy 10.16 -0.635))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 12.065 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))''',
    "focalpoint:BT_CELL": '''
			(polyline
				(pts (xy 0 -2.54) (xy 6.35 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 8.89 -2.54) (xy 15.24 -2.54))
				(stroke (width 0.254) (type default)) (fill (type none)))
			(polyline
				(pts (xy 6.35 -5.08) (xy 6.35 0))
				(stroke (width 0.508) (type default)) (fill (type none)))
			(polyline
				(pts (xy 8.89 -3.81) (xy 8.89 -1.27))
				(stroke (width 0.508) (type default)) (fill (type none)))
			(text "+" (at 5.08 -6.35 0)
				(effects (font (size 1.27 1.27))))''',
    "focalpoint:PWR_FLAG": '''
			(polyline
				(pts (xy 0 -2.54) (xy 5.08 -2.54) (xy 5.08 -6.35)
					(xy 10.16 -5.08) (xy 5.08 -3.81))
				(stroke (width 0.254) (type default))
				(fill (type none))
			)''',
}


def top_level_forms(text: str) -> list[str]:
    """Return direct children of the outer kicad_sch expression."""
    outer = text.find("(kicad_sch")
    if outer < 0:
        raise ValueError("not a KiCad schematic")
    forms: list[str] = []
    depth = 0
    start: int | None = None
    in_string = False
    escaped = False
    for index in range(outer, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
            if depth == 2:
                start = index
        elif char == ")":
            if depth == 2 and start is not None:
                forms.append(text[start : index + 1])
                start = None
            depth -= 1
            if depth == 0:
                break
    return forms


def form_name(form: str) -> str:
    match = re.match(r"\(([^\s()]+)", form)
    if not match:
        raise ValueError(f"cannot identify form: {form[:40]!r}")
    return match.group(1)


def matching_paren(text: str, start: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(start, len(text)):
        char = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unterminated S-expression")


def conventionalize_lib_symbols(lib_symbols: str, embedded: bool = True) -> str:
    """Replace stretched placeholder bodies with conventional notation."""
    result = lib_symbols
    for lib_id, graphics in CONVENTIONAL_GRAPHICS.items():
        symbol_name = lib_id if embedded else lib_id.split(":", 1)[1]
        marker = f'(symbol "{symbol_name}"'
        form_start = result.find(marker)
        if form_start < 0:
            raise ValueError(f"cached symbol not found: {lib_id}")
        form_end = matching_paren(result, form_start) + 1
        form = result[form_start:form_end]
        rectangle_start = form.find("(rectangle")
        if rectangle_start < 0:
            raise ValueError(f"placeholder rectangle not found: {lib_id}")
        rectangle_end = matching_paren(form, rectangle_start) + 1
        form = form[:rectangle_start] + graphics.strip() + form[rectangle_end:]
        result = result[:form_start] + form + result[form_end:]
    return result


def component_ref(symbol_form: str) -> str:
    match = re.search(r'\(property "Reference" "([^"]+)"', symbol_form)
    if not match:
        raise ValueError("symbol without a Reference property")
    return match.group(1)


def chunk_bounds(chunk: str) -> tuple[float, float, float, float]:
    points = [
        (float(match.group(1)), float(match.group(2)))
        for regex in (AT_RE, XY_RE)
        for match in regex.finditer(chunk)
    ]
    if not points:
        raise ValueError("circuit chunk has no coordinates")
    xs, ys = zip(*points)
    return min(xs), min(ys), max(xs), max(ys)


def translate_chunk(chunk: str, dx: float, dy: float) -> str:
    def move_at(match: re.Match[str]) -> str:
        return f"(at {float(match.group(1)) + dx:.4f} {float(match.group(2)) + dy:.4f}"

    def move_xy(match: re.Match[str]) -> str:
        return f"(xy {float(match.group(1)) + dx:.4f} {float(match.group(2)) + dy:.4f})"

    return XY_RE.sub(move_xy, AT_RE.sub(move_at, chunk))


def pack_chunks(chunks: list[str], columns: int, rows: int) -> list[str]:
    """Place independent blocks into non-overlapping cells across an A2 page."""
    grid = 2.54
    left, top, right, bottom = 15.24, 17.78, 403.86, 274.32
    cell_width = (right - left) / columns
    cell_height = (bottom - top) / rows
    if len(chunks) > columns * rows:
        raise ValueError("sheet grid does not have enough cells")
    packed: list[str] = []
    placed_bounds: list[tuple[float, float, float, float]] = []
    for index, chunk in enumerate(chunks):
        min_x, min_y, max_x, max_y = chunk_bounds(chunk)
        column = index % columns
        row = index // columns
        cell_left = left + column * cell_width
        cell_top = top + row * cell_height
        cell_right = cell_left + cell_width
        cell_bottom = cell_top + cell_height
        target_x = (cell_left + cell_right - min_x - max_x) / 2
        target_y = (cell_top + cell_bottom - min_y - max_y) / 2
        # Only translate by whole 2.54 mm grid units. This retains the exact
        # connection-grid alignment of every symbol pin, wire, and label.
        dx = round(target_x / grid) * grid
        dy = round(target_y / grid) * grid
        bounds = (min_x + dx, min_y + dy, max_x + dx, max_y + dy)
        padding = 1.27
        if (
            bounds[0] < cell_left + padding
            or bounds[1] < cell_top + padding
            or bounds[2] > cell_right - padding
            or bounds[3] > cell_bottom - padding
        ):
            ref = component_ref(chunk)
            raise ValueError(f"{ref} does not fit its non-overlap cell: {bounds}")
        packed.append(translate_chunk(chunk, dx, dy))
        placed_bounds.append(bounds)

    for index, first in enumerate(placed_bounds):
        for second in placed_bounds[index + 1:]:
            overlaps = not (
                first[2] + padding <= second[0]
                or second[2] + padding <= first[0]
                or first[3] + padding <= second[1]
                or second[3] + padding <= first[1]
            )
            if overlaps:
                raise ValueError(f"overlapping schematic blocks: {first}, {second}")
    return packed


def sheet_block(root_uuid: str, info: dict[str, object]) -> str:
    x, y = info["at"]
    width, height = info["size"]
    name = info["name"]
    filename = info["file"]
    sheet_uuid = info["sheet_uuid"]
    page = info["page"]
    return f'''\t(sheet
\t\t(at {x} {y})
\t\t(size {width} {height})
\t\t(exclude_from_sim no)
\t\t(in_bom yes)
\t\t(on_board yes)
\t\t(dnp no)
\t\t(stroke (width 0) (type solid))
\t\t(fill (color 0 0 0 0.0000))
\t\t(uuid "{sheet_uuid}")
\t\t(property "Sheetname" "{name}"
\t\t\t(at {x} {y - 0.7625} 0)
\t\t\t(effects (font (size 1.524 1.524)) (justify left bottom))
\t\t)
\t\t(property "Sheetfile" "{filename}"
\t\t\t(at {x} {y + height + 0.9901} 0)
\t\t\t(effects (font (size 1.524 1.524)) (justify left top))
\t\t)
\t\t(instances
\t\t\t(project "focalpoint"
\t\t\t\t(path "/{root_uuid}" (page "{page}"))
\t\t\t)
\t\t)
\t)'''


def child_text(
    version: str,
    lib_symbols: str,
    root_uuid: str,
    info: dict[str, object],
    chunks: list[str],
) -> str:
    instance_path = f'/{root_uuid}/{info["sheet_uuid"]}'
    old_path = f'/{root_uuid}'
    body = []
    for chunk in chunks:
        body.append(chunk.replace(f'(path "{old_path}"', f'(path "{instance_path}"'))
    title = info["name"]
    return "\n".join([
        "(kicad_sch",
        f"\t{version}",
        '\t(generator "focalpoint_hierarchy")',
        '\t(generator_version "10.0")',
        f'\t(uuid "{info["file_uuid"]}")',
        '\t(paper "A2")',
        "\t(title_block",
        f'\t\t(title "FocalPoint Rev A — {title}")',
        '\t\t(rev "A-hierarchical-standard")',
        "\t)",
        "\t" + lib_symbols.replace("\n", "\n\t"),
        *("\t" + block.replace("\n", "\n\t") for block in body),
        "\t(embedded_fonts no)",
        ")",
        "",
    ])


def main() -> None:
    if not FLAT_REFERENCE.exists():
        shutil.copy2(SCHEMATIC, FLAT_REFERENCE)
    if not SYMBOL_LIBRARY_REFERENCE.exists():
        shutil.copy2(SYMBOL_LIBRARY, SYMBOL_LIBRARY_REFERENCE)
    source = FLAT_REFERENCE.read_text()
    forms = top_level_forms(source)
    by_name = {form_name(form): form for form in forms if form_name(form) in {
        "version", "uuid", "lib_symbols"
    }}
    version = by_name["version"]
    root_uuid_match = re.search(r'\(uuid "([^"]+)"\)', by_name["uuid"])
    if not root_uuid_match:
        raise ValueError("root UUID missing")
    root_uuid = root_uuid_match.group(1)
    lib_symbols = conventionalize_lib_symbols(by_name["lib_symbols"])
    SYMBOL_LIBRARY.write_text(
        conventionalize_lib_symbols(
            SYMBOL_LIBRARY_REFERENCE.read_text(), embedded=False
        )
    )

    chunks_by_sheet: dict[str, list[str]] = {name: [] for name in SHEETS}
    seen_refs: set[str] = set()
    current_ref: str | None = None
    current_forms: list[str] = []

    def flush() -> None:
        nonlocal current_ref, current_forms
        if current_ref is None:
            return
        owners = [name for name, refs in REFS_BY_SHEET.items() if current_ref in refs]
        if len(owners) != 1:
            raise ValueError(f"{current_ref}: expected one sheet owner, got {owners}")
        chunks_by_sheet[owners[0]].append("\n".join(current_forms))
        seen_refs.add(current_ref)
        current_ref = None
        current_forms = []

    circuit_started = False
    for form in forms:
        name = form_name(form)
        if name == "symbol" and '(lib_id "' in form:
            flush()
            circuit_started = True
            current_ref = component_ref(form)
            current_forms = [form]
        elif circuit_started and name not in {"sheet_instances", "embedded_fonts"}:
            current_forms.append(form)
    flush()

    expected = set().union(*REFS_BY_SHEET.values())
    if seen_refs != expected:
        missing = sorted(expected - seen_refs)
        extra = sorted(seen_refs - expected)
        raise ValueError(f"classification mismatch: missing={missing}, extra={extra}")

    for name, info in SHEETS.items():
        output = ROOT / str(info["file"])
        output.write_text(
            child_text(
                version,
                lib_symbols,
                root_uuid,
                info,
                pack_chunks(chunks_by_sheet[name], *info["grid"]),
            )
        )

    LAYOUT_REPORT.write_text(
        "FocalPoint hierarchical schematic layout validation\n"
        "==================================================\n\n"
        "page=A2\n"
        "placement=checked fixed-cell grid\n"
        "minimum_block_gap_mm=1.27\n"
        + "".join(
            f"{name}_blocks={len(chunks_by_sheet[name])}\n"
            f"{name}_grid={info['grid'][0]}x{info['grid'][1]}\n"
            f"{name}_overlapping_block_pairs=0\n"
            for name, info in SHEETS.items()
        )
        + f"total_blocks={sum(map(len, chunks_by_sheet.values()))}\n"
        "total_overlapping_block_pairs=0\n"
        "all_blocks_inside_printable_cells=yes\n"
        "connection_grid_preserved=yes\n"
    )

    sheets = "\n".join(sheet_block(root_uuid, info) for info in SHEETS.values())
    root = f'''(kicad_sch
\t{version}
\t(generator "focalpoint_hierarchy")
\t(generator_version "10.0")
\t(uuid "{root_uuid}")
\t(paper "A4")
\t(title_block
\t\t(title "FocalPoint Rev A — System Hierarchy")
\t\t(rev "A-hierarchical")
\t)
\t(lib_symbols)
{sheets}
\t(sheet_instances
\t\t(path "/" (page "1"))
\t)
\t(embedded_fonts no)
)
'''
    SCHEMATIC.write_text(root)
    counts = {name: len(chunks) for name, chunks in chunks_by_sheet.items()}
    print(f"hierarchical schematic written: {counts}, total={sum(counts.values())}")


if __name__ == "__main__":
    main()
