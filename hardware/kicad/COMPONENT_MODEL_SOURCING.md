# Component model sourcing

Last checked: 2026-07-31

This file records the mechanical provenance of the component models used for
the Rev A enclosure check. A package-envelope model proves only package-body
clearance; it does not replace a purchased-part fit check for moving or
panel-mounted controls.

| Ref | Purchased part | Mechanical representation | Status |
| --- | --- | --- | --- |
| U3 | TI BQ24074RGTR | `FocalPoint.3dshapes/wqfn_16_1ep_3x3mm_p0_5mm_ep1_68x1_68mm.step` | Exact 3 × 3 mm, 16-pin, 0.5 mm-pitch, 1.68 × 1.68 mm exposed-pad package envelope from step.parts; SHA-256 `d030a0b2b1099d58d7e5e76de0e636896691cb3a8cdf646ea666857913807a72`. TI drawing RGT0016C specifies 2.9–3.1 mm square and 1.0 mm maximum height. |
| U9 | ADI MAX17048G+T10 | KiCad `DFN-8_2x2mm_P0.5mm.step` | Exact 2 × 2 mm external body envelope. The manufacturer identifies package code T822+3 as an 8-pin TDFN-EP; exposed-pad shape does not alter enclosure clearance. |
| ENC1 | Alps Alpine EC11E15244G1 | Enclosure opening plus datasheet-derived envelope | Manufacturer CAD is account-gated and the installed KiCad model is absent. The selected part has a 20 mm flat actuator and 0.5 mm push travel. Physical knob/shaft/panel fit remains mandatory. |
| JS1 | Alps Alpine RKJXV122400R | Parametric envelope in `../../case/freecad/enclosure.py` | Official dimensions used: 18.2 × 21.7 × 11.2 mm body, ±23° maximum motion, 0.4 mm center-push travel. The Ø20 shell opening is checked against the modeled upper frame and motion envelope. Exact manufacturer 3D CAD is account-gated; printed fit remains mandatory. |

step.parts was searched by exact manufacturer part number for all four parts.
It had no exact-MPN result for ENC1, JS1, U3, or U9. The U3 package-envelope
match above was selected by exact package dimensions and downloaded with its
catalog checksum verified. The local KiCad installation supplies the U9
external-body envelope.

Primary dimensional sources:

- Alps Alpine product pages/catalogs for EC11E15244G1 and RKJXV122400R.
- Texas Instruments BQ2407x datasheet, package drawing RGT0016C.
- Analog Devices MAX17048/MAX17049 datasheet, package code T822+3 and outline
  21-0168.

Release implication: the two missing bottom-side IC bodies are now represented
for mechanical export. ENC1 and JS1 stay explicit first-print acceptance gates
because their actuator motion, shaft/knob selection, and shell interface cannot
be proven by a static generic package model.
