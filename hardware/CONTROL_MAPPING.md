# Dynamic physical-control mapping

Rev A exposes 16 top-level physical controls. Their positions and identifiers
are stable, but their behavior is not hard-coded:

| Physical ID | Control |
|---|---|
| `key_01`…`key_12` | Frosted RGB MX selector keys, scattered 1+4+4+3 around the corner controls on the 4×4 lattice below (not a contiguous grid) |
| `key_13` | Top-row ceramic RGB key; behavior remains assignable |
| `touch_01` | Capacitive touch region |
| `encoder_01` | Rotary encoder with push |
| `joystick_01` | Analog X/Y joystick with push |

The count describes physical controls, not event count. For example,
`encoder_01` emits clockwise, counter-clockwise, and press gestures, while
`joystick_01` emits calibrated axes, directions, and press gestures.

All controls occupy a uniform 4×4 visual lattice. From the user-facing top-left
cell, the rows are:

```text
encoder    key_01    key_13   joystick
key_02     key_03    key_04   key_05
key_06     key_07    key_08   key_09
key_10     key_11    key_12   touch
```

## Mapping model

- Firmware reports physical IDs and normalized gestures; it does not decide
  that a particular position means accept, reject, focus, or reasoning level.
- The daemon owns named mapping profiles and sends the active profile to the
  device for unplugged/fallback behavior.
- A mapping target may be a FocalPoint action, session-slot focus, keyboard
  shortcut, consumer-control event, profile change, or `disabled`.
- Tap, hold, double-tap, rotation, direction, magnitude threshold, and press
  may be mapped independently where the control supports them.
- Per-key RGB identity remains independent of the input mapping. Reassigning a
  key does not implicitly reassign its LED or agent-status slot.
- Profiles are versioned and validated by capabilities reported by firmware;
  unknown actions are rejected rather than silently ignored.

## Required protocol/firmware work

The protocol side of this model is now drafted as **`PROTOCOL.md` §6
(v0.3, DRAFT — not yet implemented)**; the items below map onto it:

1. Device capability descriptor — firmware version, physical IDs, supported
   gestures, LED IDs, and mapping storage limits: drafted as the `PONG`
   extension + `GET_CAPS`/`CAPS` (PROTOCOL.md §6.2), with control IDs 17
   (`key_13`) and 18 (`touch_01`) added in §6.1.
2. Get/set/activate mapping-profile messages on USB Raw HID and BLE GATT:
   drafted as `MAP_BEGIN`/`MAP_DATA`/`MAP_COMMIT`/`MAP_ACTIVATE`/`MAP_ACK`
   plus socket-API additions (PROTOCOL.md §6.3); the BLE transport itself is
   PROTOCOL.md §6.4.
3. Store one safe fallback profile in nonvolatile device memory (profile
   slot 0 in the §6.3 draft); keep the full profile library in the daemon
   configuration.
4. Route every hardware event through the same daemon action dispatcher used
   by configurable global hotkeys. *(Daemon work; not a wire-protocol item.)*
5. Add mapping controls to the macOS settings UI with conflict detection and a
   live “press a control” identification mode. *(App work; not a wire-protocol
   item.)*

Until that draft is implemented, the existing v0.2 slot/control codes remain a
compatibility profile rather than permanent electrical assignments.
