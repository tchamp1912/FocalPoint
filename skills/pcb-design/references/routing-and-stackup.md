# Routing and stackup guidance

## Contents

- Layer selection
- Return paths and power
- Controlled impedance
- RF and switching power
- Edge clearance
- Autorouter cleanup

## Layer selection

Choose the smallest layer count that supports clean placement, continuous
returns, power integrity, and manufacturability. A strong four-layer default is:

1. F.Cu: critical and ordinary signals plus local power;
2. In1: uninterrupted GND reference;
3. In2: GND pour plus slow signals or power distribution;
4. B.Cu: signals and local power.

Separate 3.3 V and 5 V planes are not inherently necessary. Wider local routes
and pours are often better on small mixed-signal controllers. Do not use extra
layers to excuse long detours, fractured return paths, or poor placement.

## Return paths and power

Keep the primary GND plane continuous under fast signals. Avoid routing across
plane splits. Add nearby return vias at signal-layer transitions. Keep switcher
hot loops compact and follow the regulator datasheet's placement example.
Route high-current rails using current, copper thickness, temperature rise, and
transient requirements—not a generic width label.

Treat zone fill as generated state. Scripted track/via changes do not update
saved fill automatically.

## Controlled impedance

Select a real fabricator stack before calculating geometry. Record:

- stack/order code and finished thickness;
- copper thickness for every layer;
- dielectric thickness, material, Dk, and loss tangent;
- microstrip/stripline structure and reference plane;
- differential target, trace width, edge gap, and soldermask assumptions;
- calculator/source and access date.

Keep a differential pair coupled, referenced to one continuous plane, and free
of unnecessary vias. Match within the interface's actual timing budget; do not
trade gross detours for meaningless sub-millimeter matching.

## RF and switching power

Apply the radio-module vendor's antenna keepout on every copper layer and to
nearby batteries, screws, shields, and enclosure metal. Range requirements do
not remove the need for the documented keepout.

For switching regulators, minimize input loop, switch node, inductor loop, and
output return area. Keep sensitive analog and antenna regions away from the
switch node. Inspect thermal paths and exposed-pad construction.

## Edge clearance

Separate fabrication capability from a design target. Current values must be
checked against the selected fabricator, but useful internal targets are:

- ordinary tracks and via annular rings: 1.0 mm preferred on roomy prototypes;
- visibly exposed or mechanically stressed routing: 2.0 mm when practical;
- zones: 0.5–1.0 mm depending return-path needs;
- component bodies: about 2–3 mm when possible;
- edge connectors/castellations: explicit documented exceptions.

Measure to the copper edge, not the track or via center. Audit all four sides
and include tracks, via rings, pads, zones, copper graphics, and internal
cutouts. A rectangular bounding-box audit is insufficient for irregular
outlines and slots.

## Autorouter cleanup

Autorouter completion percentage is not a quality metric. After import:

- remove redundant branches and dangling vias;
- replace stair-step routes with purposeful 45-degree or smooth paths;
- shorten implausible detours around components;
- inspect layer changes and their return vias;
- keep critical pairs coupled and away from board edges;
- inspect every route near cutouts, mounting holes, RF keepouts, and connectors;
- rerun zone fill and native DRC from the saved KiCad PCB.

If routing stalls, first improve placement and local escapes. Board growth or
additional layers are later options, not the first response.
