# V1 Max ANSI encoder — debounce fix

Built 2026-09-17 for `keychron/v1_max/ansi_encoder:focalpoint`.
For that exact board/layout only. Flashed successfully on 2026-09-18; the
keyboard restarted normally and the user confirmed that repeated letters were
fixed. The original prebuilt image remains one directory above as a fallback.

- Keychron QMK: `wireless_playground`, commit `666862cb8123b64a6b96718d739c6203ad99031f`
- QMK CLI: 1.2.0; ARM GCC: 14.3.1
- Debounce: `sym_defer_pk`, 10 ms on press and release
- Binary size: 95,476 bytes (95,460-byte flash payload plus 16-byte DFU suffix)

Validation: firmware compiled and linked; build log confirmed `sym_defer_pk.c`;
ELF disassembly confirmed the 10 ms counter; exactly one `raw_hid_receive`
symbol was linked. Simulated chatter tests passed against this QMK checkout,
including overlapping keys and intentional repeat presses.

Verify with `shasum -a 256 -c SHA256SUMS` from this directory, then use the
flashing instructions in ../../README.md after confirming the exact board.

This build filters brief switch chatter; it cannot repair a faulty switch
or establish the cause of the reported repeated letters. Test typing in USB
Cable mode, then in the connection mode where the issue was observed.
