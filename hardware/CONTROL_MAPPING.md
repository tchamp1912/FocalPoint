# Dynamic physical-control mapping

Rev A exposes 16 top-level physical controls. Their positions and identifiers
are stable, but their behavior is not hard-coded:

| Physical ID | Control |
|---|---|
| `key_01`…`key_12` | Uniform 4×3 RGB MX grid |
| `key_13` | Centered ceramic RGB command key |
| `touch_01` | Capacitive touch region |
| `encoder_01` | Rotary encoder with push |
| `joystick_01` | Analog X/Y joystick with push |

The count describes physical controls, not event count. For example,
`encoder_01` emits clockwise, counter-clockwise, and press gestures, while
`joystick_01` emits calibrated axes, directions, and press gestures.

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

1. Add a device capability descriptor containing firmware version, physical
   IDs, supported gestures, LED IDs, and mapping storage limits.
2. Add get/set/activate mapping-profile messages to USB Raw HID and BLE GATT.
3. Store one safe fallback profile in nonvolatile device memory; keep the full
   profile library in the daemon configuration.
4. Route every hardware event through the same daemon action dispatcher used
   by configurable global hotkeys.
5. Add mapping controls to the macOS settings UI with conflict detection and a
   live “press a control” identification mode.

Until that protocol extension lands, the existing slot/control codes remain a
compatibility profile rather than permanent electrical assignments.
