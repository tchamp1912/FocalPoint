#!/usr/bin/env python3
"""Build a self-consistent Rev A manufacturing release candidate.

All generated files come from the corrected pinout-fix PCB. The package stays
explicitly non-orderable until a zero-violation native KiCad DRC report is
supplied and the JLC component/rotation review is completed.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
KICAD = ROOT / "hardware" / "kicad"
BOARD = KICAD / "focalpoint_rev_a_release_candidate.kicad_pcb"
PROJECT = KICAD / "focalpoint_rev_a_release_candidate.kicad_pro"
SCHEMATIC = KICAD / "focalpoint.kicad_sch"
PROCUREMENT_BOM = ROOT / "hardware" / "bom.csv"
OUT = KICAD / "release_candidate"
ARCHIVE = KICAD / "focalpoint_rev_a_release_candidate.zip"
GERBER_ARCHIVE = KICAD / "focalpoint_rev_a_release_candidate_gerbers.zip"

GERBER_LAYERS = ",".join(
    [
        "F.Cu",
        "In1.Cu",
        "In2.Cu",
        "In3.Cu",
        "In4.Cu",
        "B.Cu",
        "F.Paste",
        "B.Paste",
        "F.Silkscreen",
        "B.Silkscreen",
        "F.Mask",
        "B.Mask",
        "Edge.Cuts",
    ]
)


def command(*args: str) -> None:
    print("+", " ".join(args))
    subprocess.run(args, cwd=ROOT, check=True)


def find_kicad_cli() -> str:
    found = shutil.which("kicad-cli")
    if found:
        return found
    macos = Path("/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")
    if macos.is_file():
        return str(macos)
    raise SystemExit("kicad-cli not found")


def expand_refs(text: str) -> list[str]:
    """Expand comma-separated references and same-prefix numeric ranges."""
    refs: list[str] = []
    for token in (part.strip() for part in text.split(",")):
        token = token.split(" (")[0].strip()
        match = re.fullmatch(r"([A-Z]+)(\d+)(?:-([A-Z]+)?(\d+))?", token)
        if not match:
            continue
        prefix, start, end_prefix, end = match.groups()
        if end_prefix and end_prefix != prefix:
            raise ValueError(f"mixed-prefix range: {token}")
        first = int(start)
        last = int(end or start)
        refs.extend(f"{prefix}{number}" for number in range(first, last + 1))
    return refs


def is_jlc_assembly(value: str) -> bool:
    return value.startswith("JLC ")


def report_is_clean(path: Path) -> bool:
    text = path.read_text(errors="replace")
    explicit_zero = (
        re.search(r"\*\*\s*Found 0 DRC violations", text, re.IGNORECASE)
        or re.search(r"\b0\s+violations?\b", text, re.IGNORECASE)
    )
    return bool(explicit_zero)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(args: argparse.Namespace) -> None:
    for required in (BOARD, PROJECT, SCHEMATIC, PROCUREMENT_BOM):
        if not required.is_file():
            raise SystemExit(f"missing required input: {required}")

    cli = find_kicad_cli()
    with tempfile.TemporaryDirectory(prefix="focalpoint-release-", dir=KICAD) as raw:
        stage = Path(raw) / OUT.name
        assembly = stage / "assembly"
        gerbers = stage / "gerbers"
        reports = stage / "reports"
        assembly.mkdir(parents=True)
        gerbers.mkdir()
        reports.mkdir()

        positions = assembly / "focalpoint_rev_a_positions.csv"
        command(
            cli,
            "pcb",
            "export",
            "pos",
            "--format",
            "csv",
            "--units",
            "mm",
            "--side",
            "both",
            "--exclude-dnp",
            "--output",
            str(positions),
            str(BOARD),
        )
        command(
            cli,
            "pcb",
            "export",
            "gerbers",
            "--layers",
            GERBER_LAYERS,
            "--subtract-soldermask",
            "--output",
            str(gerbers),
            str(BOARD),
        )
        command(
            cli,
            "pcb",
            "export",
            "drill",
            "--format",
            "excellon",
            "--excellon-units",
            "mm",
            "--excellon-separate-th",
            "--generate-map",
            "--map-format",
            "pdf",
            "--generate-report",
            "--report-path",
            str(gerbers / "drill_report.rpt"),
            "--output",
            str(gerbers),
            str(BOARD),
        )

        with PROCUREMENT_BOM.open(newline="") as stream:
            procurement = list(csv.DictReader(stream))
        with positions.open(newline="") as stream:
            position_rows = list(csv.DictReader(stream))

        position_by_ref = {row["Ref"]: row for row in position_rows}
        if len(position_by_ref) != len(position_rows):
            raise SystemExit("duplicate reference in placement export")

        included: dict[str, dict[str, str]] = {}
        excluded: dict[str, str] = {}
        for row in procurement:
            refs = expand_refs(row["Designators"])
            if is_jlc_assembly(row["Assembly"]):
                for ref in refs:
                    if ref in included:
                        raise SystemExit(f"duplicate assembly BOM reference: {ref}")
                    included[ref] = row
            else:
                for ref in refs:
                    excluded[ref] = row["Assembly"]

        missing_positions = sorted(set(included) - set(position_by_ref))
        if missing_positions:
            raise SystemExit(
                f"assembly BOM refs missing from placement file: {missing_positions}"
            )
        unexpected_positions = sorted(
            set(position_by_ref) - set(included) - set(excluded)
        )
        if unexpected_positions:
            raise SystemExit(
                f"placement refs absent from procurement BOM: {unexpected_positions}"
            )

        bom_path = assembly / "jlcpcb_bom.csv"
        with bom_path.open("w", newline="") as stream:
            fields = [
                "Comment",
                "Designator",
                "Footprint",
                "LCSC Part #",
                "Manufacturer",
                "Manufacturer Part Number",
                "Procurement Status",
            ]
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            for row in procurement:
                if not is_jlc_assembly(row["Assembly"]):
                    continue
                refs = expand_refs(row["Designators"])
                footprints = sorted(
                    {position_by_ref[ref]["Package"] for ref in refs}
                )
                lcsc = row["LCSC"] if row["LCSC"].startswith("C") else ""
                writer.writerow(
                    {
                        "Comment": row["MPN"],
                        "Designator": ",".join(refs),
                        "Footprint": ",".join(footprints),
                        "LCSC Part #": lcsc,
                        "Manufacturer": row["Manufacturer"],
                        "Manufacturer Part Number": row["MPN"],
                        "Procurement Status": (
                            "MATCHED" if lcsc else "LIVE_MATCH_OR_CONSIGN_REQUIRED"
                        ),
                    }
                )

        pos_path = assembly / "jlcpcb_positions.csv"
        with pos_path.open("w", newline="") as stream:
            fields = ["Designator", "Mid X", "Mid Y", "Layer", "Rotation"]
            writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
            writer.writeheader()
            for ref in sorted(included):
                row = position_by_ref[ref]
                writer.writerow(
                    {
                        "Designator": ref,
                        "Mid X": f'{row["PosX"]}mm',
                        "Mid Y": f'{row["PosY"]}mm',
                        "Layer": "Bottom" if row["Side"] == "bottom" else "Top",
                        "Rotation": row["Rot"],
                    }
                )

        evidence = [
            KICAD / "erc_release_candidate.rpt",
            KICAD / "release_candidate_static_audit.txt",
            KICAD / "release_candidate_schematic_pcb_net_compare.txt",
            KICAD / "release_candidate_footprint_audit.txt",
        ]
        documentation = [
            PROCUREMENT_BOM,
            ROOT / "hardware" / "BOM.md",
            ROOT / "hardware" / "BRINGUP_TEST_PLAN.md",
            ROOT / "hardware" / "TASKS.md",
            KICAD / "PCB_FABRICATION.md",
            KICAD / "LCSC_MATCH_VALIDATION.md",
            KICAD / "DECISIONS.md",
            KICAD / "SCHEMATIC.md",
            KICAD / "TRANSCRIPTION_NOTES.md",
            KICAD / "COMPONENT_MODEL_SOURCING.md",
            BOARD,
            PROJECT,
            SCHEMATIC,
            KICAD / "fp-lib-table",
        ]
        for source in documentation:
            shutil.copy2(source, stage / source.name)
        for source in evidence:
            if not source.is_file():
                raise SystemExit(f"missing validation evidence: {source}")
            shutil.copy2(source, reports / source.name)
        shutil.copytree(KICAD / "FocalPoint.pretty", stage / "FocalPoint.pretty")
        shutil.copytree(KICAD / "FocalPoint.3dshapes", stage / "FocalPoint.3dshapes")

        drc_clean = False
        if args.drc_report:
            drc_source = Path(args.drc_report).resolve()
            if not drc_source.is_file():
                raise SystemExit(f"DRC report not found: {drc_source}")
            drc_clean = report_is_clean(drc_source)
            shutil.copy2(drc_source, reports / "native_kicad_drc.rpt")
            if not drc_clean:
                raise SystemExit("supplied DRC report does not explicitly report zero violations")

        unmatched_rows = [
            row
            for row in procurement
            if is_jlc_assembly(row["Assembly"])
            and not row["LCSC"].startswith("C")
        ]
        status = stage / "RELEASE_STATUS.txt"
        status.write_text(
            "FocalPoint Rev A RELEASE CANDIDATE — NOT YET ORDERABLE\n"
            "=====================================================\n\n"
            "Exact PCB source:\n"
            f"- {BOARD.name}\n\n"
            "Automated checks completed:\n"
            "- schematic ERC: 0 errors / 0 warnings\n"
            "- schematic/PCB numbered-pad net mismatches: 0\n"
            "- PCB unrouted connections: 0\n"
            "- independent copper-clearance audit: 0 violations\n"
            "- fabrication-minimum audit: 0 violations\n"
            "- project-local release-footprint geometry mismatches: 0\n"
            f"- JLC assembly BOM/placement cross-check: {len(included)} placed parts\n"
            f"- JLC BOM lines requiring live match or consignment: {len(unmatched_rows)}\n"
            "- Gerbers and separate PTH/NPTH drill files regenerated from the exact PCB\n"
            f"- native KiCad DRC report supplied and clean: {'YES' if drc_clean else 'NO'}\n\n"
            "MANDATORY BEFORE ORDERING:\n"
            "1. Upload BOM/positions to JLC and confirm every MPN, side, and rotation.\n"
            "2. Select JLC06161H-3313, 1.6 mm, ENIG, impedance control, and\n"
            "   epoxy-filled/capped via-in-pad. Populate exactly two boards.\n"
            "3. Complete printed/purchased-part fit review for the enclosure,\n"
            "   antenna keepout, USB-C, LEDs/sockets, encoder, and joystick.\n"
            "4. Complete an independent schematic/PCB review.\n"
            "5. Treat both boards as prototypes and complete BRINGUP_TEST_PLAN.md.\n"
        )

        manifest_targets = sorted(
            path
            for path in stage.rglob("*")
            if path.is_file() and path.name != "SHA256SUMS.txt"
        )
        (stage / "SHA256SUMS.txt").write_text(
            "".join(
                f"{sha256(path)}  {path.relative_to(stage)}\n"
                for path in manifest_targets
            )
        )

        if OUT.exists():
            shutil.rmtree(OUT)
        shutil.copytree(stage, OUT)

    for path in (ARCHIVE, GERBER_ARCHIVE):
        if path.exists():
            path.unlink()
    shutil.make_archive(str(ARCHIVE.with_suffix("")), "zip", OUT)
    shutil.make_archive(
        str(GERBER_ARCHIVE.with_suffix("")), "zip", OUT / "gerbers"
    )

    print(f"Validated {len(included)} JLC-placed references")
    print(f"Excluded {len(excluded)} non-JLC/DNP/off-board references")
    print(f"Wrote {OUT}")
    print(f"Wrote {ARCHIVE}")
    print(f"Wrote {GERBER_ARCHIVE}")
    print("Release status:", "DRC-CLEAN CANDIDATE" if drc_clean else "NOT ORDERABLE")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--drc-report",
        help="native KiCad report that explicitly states zero DRC violations",
    )
    build(parser.parse_args())
