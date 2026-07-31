# Rev A LCSC exact-match validation — 2026-07-30

These mappings were checked against current official LCSC product pages by
exact manufacturer part number and package. Stock is volatile and must still
be reconfirmed in JLCPCB's live assembly matcher at order time.

| MPN | LCSC | Package / purpose | Official listing |
| --- | --- | --- | --- |
| RC0603FR-075K1L | C105580 | 0603, 5.1 kΩ | https://www.lcsc.com/product-detail/C105580.html |
| RC0603FR-072K21L | C273748 | 0603, 2.21 kΩ | https://www.lcsc.com/product-detail/C273748.html |
| RC0603FR-073K09L | C185334 | 0603, 3.09 kΩ | https://www.lcsc.com/product-detail/C185334.html |
| RC0603FR-07732KL | C246003 | 0603, 732 kΩ | https://www.lcsc.com/product-detail/C246003.html |
| RC0603FR-07100KL | C14675 | 0603, 100 kΩ | https://www.lcsc.com/product-detail/C14675.html |
| RC0603FR-0710KL | C98220 | 0603, 10 kΩ | https://www.lcsc.com/product-detail/C98220.html |
| RC0603FR-074K7L | C99782 | 0603, 4.7 kΩ | https://www.lcsc.com/product-detail/C99782.html |
| GRM188R61A105KA61D | C86012 | 0603, 1 µF 10 V | https://www.lcsc.com/product-detail/C86012.html |
| GRM188B31A106ME69D | C162265 | 0603, 10 µF 10 V | https://www.lcsc.com/product-detail/C162265.html |
| CL10A226MP7LUNC | C2762595 | 0603, 22 µF 10 V | https://www.lcsc.com/product-detail/C2762595.html |
| GRM1885C1H221GA01D | C440180 | 0603, 220 pF 50 V C0G | https://www.lcsc.com/product-detail/C440180.html |
| GRM188R71H103KA01D | C77053 | 0603, 10 nF 50 V X7R | https://www.lcsc.com/product-detail/C77053.html |
| PESD5V0U2BT,215 | C85399 | SOT-23, dual 5 V bidirectional ESD | https://www.lcsc.com/product-detail/C85399.html |
| RMS06FT2941 | C209098 | 0603, 2.94 kΩ | https://www.lcsc.com/product-detail/C209098.html |
| RC0603FR-0746K4L | C165747 | 0603, 46.4 kΩ | https://www.lcsc.com/product-detail/C165747.html |
| RC0603FR-071KL | C22548 | 0603, 1 kΩ | https://www.lcsc.com/product-detail/C22548.html |
| RC0603FR-0733RL | C108661 | 0603, 33 Ω | https://www.lcsc.com/product-detail/C108661.html |

The 22 µF output capacitors remain a prototype electrical validation item:
their nominal value and voltage rating match the design and their package now
matches the PCB, but effective capacitance under 5 V DC bias must be validated
by the assembled +5V rail load test.

Every JLC assembly BOM line now has an exact LCSC catalog mapping. This does
not prove current JLC assembly stock; every line still requires live matcher
confirmation before the order is submitted.
