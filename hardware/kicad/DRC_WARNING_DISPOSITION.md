# Historical Rev A DRC warning disposition

This document records the superseded six-layer cleanup. The authoritative Rev
B evidence is `focalpoint_rev_b_4layer_release_DRC.rpt` for
`focalpoint_rev_b_4layer_release_candidate.kicad_pcb`; it reports zero
violations, zero unconnected pads, and zero footprint errors.

Authoritative report: `DRC_release_candidate_native.rpt`

Authoritative PCB: `focalpoint_rev_a_release_candidate.kicad_pcb`
Native KiCad result: 0 violations, 0 unconnected pads, 0 footprint errors

This record explains every warning repair and the one ignored checker category.
It is not permission to order the PCB; mechanical and human-review gates remain.

## Repaired

The earlier `drcfix2` checkpoint contained 183 warnings. The promoted release
candidate repairs these classes:

| Class | Before | After | Disposition |
| --- | ---: | ---: | --- |
| Hole-to-hole | 18 | 0 | Removed duplicate power vias and reduced four closely paired via drills from 0.40 mm to 0.25 mm while retaining 0.60 mm lands. |
| Connection width | 9 | 0 | Removed duplicate via necks and widened the affected GND, SYS, and +5V_LED breakout copper. |
| Dangling via | 6 | 0 | Removed redundant autorouter vias. |
| Dangling track | 14 | 0 | Iteratively removed complete redundant autorouter branches with native DRC after every pass. |
| Silkscreen over copper | 81 | 0 | Hid only DRC-identified crowded reference fields and moved affected decorative footprint outlines to fabrication layers. |
| Silkscreen overlap | 33 | 0 | Applied the same targeted reference/outline cleanup; copper, mask, paste, pads, and placement were unchanged. |
| Library footprint mismatch | 22 initially / 37 after intentional silk edits | 0 reported | Vendored all affected embedded geometries as unique release footprints and independently audited them. See the exception below. |

The result introduces no native clearance, copper-edge, drill-spacing,
connection-width, silkscreen, or unconnected-item violation. The independent
`release_candidate_static_audit.txt` also reports zero clearance and
fabrication-minimum violations.

## Electrical routing

No dangling-track or dangling-via warning remains. The KEY7, TOUCH_OUT,
RGB_DATA, and KEY9 warnings proved to be redundant autorouter branches. Each
branch was peeled back one segment at a time; native KiCad DRC and the
connectivity guard continued to report zero unconnected items after every
deletion. The intended pad-to-pad routes remain present.

## Project-local footprint exception

Thirty-seven affected footprints are linked to unique entries in
`FocalPoint.pretty`. `audit_release_footprints.py` re-exports every embedded
release footprint and compares it with the project-local library while ignoring
only regenerated UUID metadata. `release_candidate_footprint_audit.txt` records
37 footprints and 0 geometry mismatches.

KiCad 10 still reports J3 and U1 as library mismatches even when their exported
library files differ from the embedded copies only in property UUID metadata.
For that reason, and only after the independent geometry audit was added, the
project sets `lib_footprint_mismatch` to `ignore`. The native DRC report lists
that category under **Ignored checks** so the exception remains visible.

Release discipline for this exception:

1. Never update the release footprints from a global KiCad library.
2. Run `audit_release_footprints.py` before every package build.
3. Treat any footprint count other than 37 or any geometry mismatch as a hard
   release failure.
4. The exact manufacturer land-pattern review and JLC placement preview remain
   mandatory human gates.

## Silkscreen

All 114 silkscreen warnings are repaired rather than waived. Crowded reference
fields named by DRC are hidden, and affected decorative footprint outlines are
preserved on fabrication layers instead of printed over exposed pads. Unflagged
markings remain. The final JLC Gerber preview still needs a human legibility
check for polarity, pin 1, connector orientation, and battery polarity.
