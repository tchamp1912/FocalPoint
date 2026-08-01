#!/usr/bin/env python3
"""Require a KiCad DRC report with all three release-zero statements."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    text = args.report.read_text(errors="replace")
    checks = {
        "drc_violations": r"\*\*\s*Found 0 DRC violations",
        "unconnected": r"\*\*\s*Found 0 unconnected (?:pads|items)",
        "footprint_errors": r"\*\*\s*Found 0 Footprint errors",
    }
    failed = [name for name, pattern in checks.items() if not re.search(pattern, text, re.I)]
    for name in checks:
        print(f"{name}={'FAIL' if name in failed else 'PASS'}")
    if failed:
        raise SystemExit("DRC release gate failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
