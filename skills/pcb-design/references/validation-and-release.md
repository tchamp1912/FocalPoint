# Validation and release

## Contents

- Automated gates
- Visual and mechanical review
- Manufacturing package
- Order review
- Physical gates

## Automated gates

Require reports tied to the exact PCB filename and revision:

1. ERC: zero unresolved errors and warnings.
2. Native DRC: zero violations, zero unconnected pads/items, zero footprint
   errors.
3. XML schematic netlist versus PCB numbered-pad mapping: zero mismatches.
4. Independent copper collision and fab-minimum audit: zero violations.
5. External-edge audit: targets met or each intentional exception documented.
6. Project-local footprint audit: embedded geometry matches the locked library.
7. Release archive integrity: every ZIP tests clean and every manifest hash
   matches.

Never parse only the phrase "0 violations"; also require zero unconnected and
zero footprint errors. Do not treat ignored checker categories as invisible:
list them and justify why they are safe.

## Visual and mechanical review

Inspect each copper, mask, paste, silk, and edge layer. Confirm:

- filled planes exist and return paths are continuous;
- antenna keepouts apply across copper and enclosure;
- polarity, pin 1, LED direction, socket orientation, assembly side, and
  rotation are correct;
- connector shells and openings align;
- moving controls clear neighboring caps and the enclosure through full travel;
- bosses, fasteners, battery, cable bends, reset access, and programming tools
  clear the populated PCB;
- paste apertures and via-in-pad treatment match the assembler process.

Use exact manufacturer CAD where available. A simplified body model is not
proof of panel or moving-part fit.

## Manufacturing package

Generate from one authoritative PCB in a clean staging directory:

- all copper Gerbers in stack order;
- masks, paste, silkscreen, and Edge.Cuts;
- Gerber job file;
- separate PTH and NPTH Excellon drills plus drill report/map;
- assembly BOM and both-side centroid/position file;
- schematic, PCB, project, local symbols/footprints/models;
- ERC, DRC, parity, footprint, edge, and static-audit reports;
- fabrication/assembly/bring-up instructions;
- release status and SHA-256 manifest.

Cross-check every assembly BOM reference against the placement export. Reject
duplicate references, missing placements, and unexplained placement-only parts.
Test ZIP contents and verify the checksum manifest after final generation.

## Order review

In the fabricator UI, verify the rendered outline, layer order, drills, slots,
stack selection, copper weights, finish, impedance control, via treatment,
component matches, substitutions, side, and rotation. Capture the approved
choices. The uploaded Gerbers normally govern over included source files.

## Physical gates

Do not call a PCB production-proven before prototypes pass:

- visual assembly and polarity inspection;
- resistance/short checks before power;
- current-limited rail sequencing and thermal checks;
- programming and recovery access;
- USB enumeration/data test in both connector orientations;
- every key/control/analog/touch channel;
- RGB walking-one and maximum-current limit;
- battery measurement, charge status, closed-case charging temperature;
- BLE/RF range with the final enclosure;
- full enclosure fit and control travel.

For a two-device prototype, test both units. A successful first power-on is not
a substitute for the complete bring-up plan.
