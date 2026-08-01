---
name: pcb-design
description: Design, modify, audit, and package manufacturable KiCad PCBs, including hierarchical schematics, footprints, placement, layer stacks, routing, controlled impedance, RF and mechanical keepouts, ERC/DRC, schematic-to-PCB net parity, copper-edge checks, Gerbers, drills, BOM/centroid data, and prototype release gates. Use for KiCad `.kicad_sch`, `.kicad_pcb`, and `.kicad_pro` work; PCB layout/routing reviews; JLCPCB or other fab preparation; autorouter cleanup; board/enclosure integration; and questions about whether a board is safe to order.
---

# PCB Design

Build evidence-backed prototype hardware without confusing a clean DRC with a
guaranteed working product. Preserve authoritative sources, make fabrication
assumptions explicit, and keep physical validation as a release gate.

## Start with an audit

1. Locate repository instructions and identify dirty user changes.
2. Find the authoritative schematic root, child sheets, PCB, project, BOM,
   enclosure, firmware pin map, and task/release record.
3. Record the KiCad version and discover `kicad-cli` and its matching `pcbnew`
   Python interpreter. Do not mix KiCad major versions.
4. Inspect the existing ERC/DRC reports, layer stack, netclasses, zones,
   footprint provenance, unrouted count, board outline, and fabrication notes.
5. State what is verified, inferred, provisional, and physically untested.

Read [workflow.md](references/workflow.md) for end-to-end sequencing. Read
[kicad-cli.md](references/kicad-cli.md) before automating KiCad.

## Maintain source-of-truth discipline

- Choose one authoritative board and project pair. Never generate release
  outputs from a similarly named intermediate.
- Treat the schematic as connectivity authority and the PCB as physical copper
  authority. Compare numbered schematic pins with PCB pad nets after remaps.
- Keep hierarchical sheets functional: power, controller/signals, and
  peripherals are a useful default. Use standard symbols, readable signal flow,
  full-page layouts, and no overlaps.
- Vendor or lock modified footprints in a project-local library. Validate pad
  numbering and land patterns against manufacturer drawings, not names.
- Record design decisions and evidence paths in the project task/release file.

## Design in bounded stages

1. Freeze requirements, inputs, board outline, connector datum, mounting, and
   enclosure constraints.
2. Validate power topology, current budgets, startup states, USB, RF, analog,
   protection, programming, and test access.
3. Select the fabricator and an orderable stack before calculating impedance.
4. Place connectors and mechanical controls first; then RF, switching power,
   decoupling, controller, and remaining passives.
5. Route critical nets manually, preserve return paths, then route ordinary
   signals and local power. Refill zones after copper changes.
6. Use an autorouter only as a draft. Import into a candidate, inspect every
   remaining connection and high-risk corridor, and never promote its session
   file directly.
7. Run all validation gates, build outputs from the exact accepted PCB, and
   hash the package.

Read [routing-and-stackup.md](references/routing-and-stackup.md) for layer,
power, USB, RF, edge, and route-quality guidance.

## Require evidence beyond DRC

Before calling a PCB release-ready, require:

- schematic ERC with zero unresolved violations;
- native PCB DRC with zero violations, zero unconnected items, and zero
  footprint errors;
- schematic XML netlist to PCB numbered-pad parity;
- independent copper and fabrication-minimum audit;
- external-edge audit covering tracks, via annular rings, pads, and pours;
- footprint geometry/provenance audit;
- visual review of every layer, zone return path, antenna keepout, connector,
  and mechanical interface;
- Gerber, drill, BOM, placement, source, evidence, and checksum integrity;
- live fabricator DFM/component/side/rotation review; and
- independent electrical review plus physical prototype bring-up.

Use the bundled scripts where applicable:

```sh
python3 scripts/validate_drc_report.py final_DRC.rpt
python3 scripts/compare_kicad_netlist.py schematic.xml board.kicad_pcb parity.txt
KICAD_PYTHON scripts/kicad_edge_audit.py board.kicad_pcb \
  --min-track 1.0 --min-via 1.0 --min-pad 1.0 --min-zone 0.5 \
  --allow '^pad:J1\.SH'
```

Replace `KICAD_PYTHON` with the Python binary bundled with the installed KiCad.
The edge audit assumes a rectangular external outline; use native geometric
checks for irregular outlines.

Read [validation-and-release.md](references/validation-and-release.md) before
claiming order readiness or generating manufacturing data.

## Handle fabrication facts carefully

- Browse current primary fabricator documentation for capabilities, stackups,
  costs, assembly constraints, and impedance geometry. These facts change.
- Save the selected stack name, copper weights, dielectric thicknesses and Dk,
  impedance structure, trace width/gap, source URL, and access date.
- Distinguish absolute fab minimums from internal design targets. Prefer margin.
- Treat edge connectors, castellations, antennas, and intentional edge plating
  as documented exceptions rather than weakening a global rule silently.
- Do not promise that CAD will assemble or function. State the exact remaining
  human, supplier, and physical gates.

## Preserve useful failure lessons

- DRC can pass copper placed uncomfortably close to an edge if the configured
  rule mirrors the fabricator's absolute minimum.
- A track-only edge audit misses via annular rings, pads, and zone pours.
- Saved zone fill becomes stale after scripted copper movement; refill before
  final DRC and plotting.
- Autorouters optimize connectivity, not aesthetics, return paths, RF quality,
  assembly risk, or enclosure intent.
- More layers can hide poor placement/routing. Reconsider topology and placement
  before paying for layers.
- Session files are not authoritative PCB files and may be malformed or only
  partially routed.
- GUI and CLI results must come from the same saved board revision.

Read [vibekey-case-study.md](references/vibekey-case-study.md) when working in
this repository or when a concrete four-layer controller example is useful.
