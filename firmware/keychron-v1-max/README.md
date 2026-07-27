# FocalPoint firmware — Keychron V1 Max (ANSI, knob)

Custom QMK keymap that turns a **Keychron V1 Max** into a FocalPoint status
display + control surface while remaining a fully usable everyday keyboard.
It implements the device side of [`PROTOCOL.md`](../../PROTOCOL.md) §1–§2 over
USB Raw HID, so `focalpointd` can paint agent state onto the keys and receive
key/dial events.

Target board: `keychron/v1_max/ansi_encoder` (the knob variant).

---

## What it does

- **Normal keyboard, always.** Layers 0–3 are the stock Keychron Mac/Win base +
  Fn layers, unchanged except that **Right-Ctrl becomes the FocalPoint hold key**
  (`MO(FOCALPOINT)`). Wireless (Bluetooth / 2.4 GHz) is untouched.
- **RGB status painting** (over whatever RGB effect you run), via
  `rgb_matrix_indicators_advanced_user`:
  - Number-row keys `1 2 3 4 5 6 7 8 9 0 - =` are **session slots 1–12**
    (`SET_KEY_STATE`).
  - **Esc** shows the **aggregate** state (`SET_STATE`); aggregate `idle` paints
    nothing (the key shows your normal effect).
  - State colors (simplified static/blink): `thinking` = purple breathing,
    `running` = amber, `waiting` = blue slow blink, `done` = green,
    `error` = red fast blink. An empty slot (`0xFF`) paints nothing.
- **FocalPoint control layer** (hold Right-Ctrl):
  - number keys `1`–`=` → `KEY_EVENT` for user keys 1–12 (control IDs 4–15)
  - `A` / `R` / `N` → accept / reject / new-task (control IDs 0 / 1 / 2)
  - `Space` → push-to-talk (control ID 3, sends **press and release**)
  - knob rotation → `DIAL` (±1); knob press → dial-press (control ID 16)
- **Graceful degradation.** The FocalPoint control keys only emit HID events when a
  daemon has attached (`SET_HOST_MODE 1`). With no daemon they are no-ops (they
  never type stray characters). The knob still does volume when detached.

---

## Layer / keycode design

| Layer | # | How reached | Contents |
|-------|---|-------------|----------|
| `MAC_BASE` | 0 | default (Mac switch) | stock, Right-Ctrl = `MO(FOCALPOINT)` |
| `MAC_FN`   | 1 | hold stock Fn | stock |
| `WIN_BASE` | 2 | OS switch = Win | stock, Right-Ctrl = `MO(FOCALPOINT)` |
| `WIN_FN`   | 3 | hold stock Fn | stock |
| `FOCALPOINT`  | 4 | **hold Right-Ctrl** | control surface below |

FocalPoint layer (transparent everywhere else, so held typing still works):

| Physical key | Keycode | Emits |
|--------------|---------|-------|
| `1`…`=` (number row) | `VK_UK1`…`VK_UK12` | `KEY_EVENT` control 4…15 |
| `A` | `VK_ACC` | `KEY_EVENT` control 0 (accept) |
| `R` | `VK_REJ` | `KEY_EVENT` control 1 (reject) |
| `N` | `VK_NEW` | `KEY_EVENT` control 2 (new-task) |
| `Space` | `VK_PTT` | `KEY_EVENT` control 3, press **and** release |
| knob turn | (encoder) | `DIAL` ±1 |
| knob press | `VK_DIALP` | `KEY_EVENT` control 16 (dial press) |

Custom keycodes are allocated from `NEW_SAFE_RANGE` (Keychron reuses the low
`QK_KB_*` range for its own keycodes).

### Non-knob variant

The V1 Max ANSI ships only as `ansi_encoder` in the Keychron fork, so the knob
is assumed present. If you build a hypothetical non-encoder variant, the DIAL
rotation and `VK_DIALP` press simply never fire — remove the `[FOCALPOINT]`
`encoder_map` row and the `encoder_update_user` block, everything else is
unchanged.

---

## LED index mapping (derived from `g_led_config`)

Read from `keyboards/keychron/v1_max/ansi_encoder/ansi_encoder.c` (matrix→LED
map) and cross-checked against the default keymap. **Not guessed.**

| Physical key | Matrix | LED index | FocalPoint role |
|--------------|--------|-----------|--------------|
| Esc | `[0,0]` | **0** | aggregate (`SET_STATE`) |
| `1` | `[1,1]` | **15** | session slot 1 |
| `2` | `[1,2]` | 16 | slot 2 |
| `3` | `[1,3]` | 17 | slot 3 |
| `4` | `[1,4]` | 18 | slot 4 |
| `5` | `[1,5]` | 19 | slot 5 |
| `6` | `[1,6]` | 20 | slot 6 |
| `7` | `[1,7]` | 21 | slot 7 |
| `8` | `[1,8]` | 22 | slot 8 |
| `9` | `[1,9]` | 23 | slot 9 |
| `0` | `[1,10]` | 24 | slot 10 |
| `-` | `[1,11]` | 25 | slot 11 |
| `=` | `[1,12]` | 26 | slot 12 |

So session slots 1–12 are LED indices `15 + (slot-1)` (`VK_LED_SESSION_BASE 15`
in `focalpoint.c`), and Esc is LED index `0`.

---

## Raw HID / protocol conformance

`focalpoint.c` provides `raw_hid_receive()` and handles the exact command IDs,
payloads, and state IDs from `PROTOCOL.md` §2 — nothing on the wire deviates:

- Host→device: `PING (0x00)`, `SET_STATE (0x01)`, `SET_LED (0x02)`,
  `SET_HOST_MODE (0x03)`, `SET_KEY_STATE (0x04)`.
- Device→host: `PONG (0x80)` (major, minor, key count = 12),
  `KEY_EVENT (0x81)`, `DIAL (0x82)`. `JOY (0x83)` is never emitted (no
  joystick on this hardware — allowed by the protocol).
- 32-byte reports on QMK's default Raw HID interface: usage page `0xFF60`,
  usage `0x61` — the daemon matches on usage page and accepts the stock
  Keychron VID/PID (`0x3434` / `0x0913`).

`SET_HOST_MODE` defaults to **off** and reverts to off on USB suspend/reset
(`suspend_power_down_user`), so the board is a plain keyboard until a daemon
attaches.

**`SET_LED (0x02)` — implemented (minimal).** `index` is interpreted as a
user-key number `1–12` (same numbering as `SET_KEY_STATE`) and paints that
number-row key; `index == 0xFF` paints all twelve. The override persists until
the next `SET_STATE`, per the protocol note. Indices outside `1–12`/`0xFF` are
ignored.

### VIA is disabled (trade-off)

VIA owns the Raw HID endpoint and its command IDs collide with ours, so this
keymap sets `VIA_ENABLE = no`. Consequence: **the Keychron Launcher / VIA
remapping GUI will not work with this firmware.** Flashing back to stock
Keychron firmware restores VIA (see below). Keychron's own HID commands
(`0xA0–0xAB`: Launcher version query, language, wireless LPM config, factory
test, BT-module DFU) are preserved — `focalpoint.c` re-services them by delegating
to the Keychron common code.

### Wireless / USB-only caveat

Raw HID works **only over the USB cable**. Over Bluetooth / 2.4 GHz the daemon
cannot reach the board, so FocalPoint status/painting and control events are inert
— but the keyboard still works as a normal wireless keyboard. The firmware
never pushes HID events unless host mode is on *and* the USB transport is
active (`get_transport() & TRANSPORT_USB`), so the wireless stack is never
disturbed.

---

## Build

Requires the QMK CLI + ARM toolchain and Keychron's fork (the V1 Max is **not**
in upstream QMK):

```bash
# 1. Toolchain (macOS)
brew install qmk/qmk/qmk        # pulls arm-none-eabi-gcc

# 2. Keychron fork, wireless branch
git clone --depth 1 --single-branch --branch wireless_playground \
    https://github.com/Keychron/qmk_firmware
cd qmk_firmware
make git-submodule            # or: qmk git-submodule

# 3. Drop this keymap in (symlink keeps it editable in the focalpoint repo)
/path/to/focalpoint/firmware/keychron-v1-max/install.sh "$PWD"

# 4. Compile
qmk compile -kb keychron/v1_max/ansi_encoder -km focalpoint
```

The artifact is `keychron_v1_max_ansi_encoder_focalpoint.bin`. A prebuilt copy
(plus `.hex`, `.elf`) and its SHA256 are in [`build/`](build/).

Verified build (QMK CLI 1.2.0, arm-none-eabi-gcc 14.3.1, Keychron fork
`wireless_playground`):

```
Linking: .build/keychron_v1_max_ansi_encoder_focalpoint.elf   [OK]
Creating binary load file for flashing: ...focalpoint.bin     [OK]
Creating load file for flashing: ...focalpoint.hex            [OK]
Size after:
   text	   data	    bss	    dec	    hex	filename
      0	  62400	      0	  62400	   f3c0	keychron_v1_max_ansi_encoder_focalpoint.bin
```

(`arm-none-eabi-size` on the `.elf`: text 60480, data 1920, bss 63616.)

SHA256 (`build/SHA256SUMS`):

```
10f40fae75331de008c1c13406ac4fbd58355baa6bdfc3698012ffe54284e20e  keychron_v1_max_ansi_encoder_focalpoint.bin
```

---

## Flashing

The V1 Max uses an STM32 (ARM) MCU in DFU bootloader mode.

1. **Enter bootloader:** unplug the keyboard, hold **Esc** (top-left) while
   plugging the USB-C cable back in. The board enumerates as an STM32 DFU
   device. (The V1 Max PCB also has a physical reset button under the space bar
   / inside the case as a fallback — long-press it, or short the `RESET` pads.)
2. **Flash:**
   - **QMK Toolbox:** open the `.bin`, select the STM32 DFU device, click Flash.
   - **CLI:** `qmk flash -kb keychron/v1_max/ansi_encoder -km focalpoint`
     (put the board in bootloader first).
3. Unplug/replug. The keyboard boots as a plain keyboard; FocalPoint features light
   up once `focalpointd` attaches over USB.

> Verify the exact bootloader gesture for your unit against Keychron's current
> instructions — some batches document holding Esc, others a reset key. The
> gesture does not change the firmware here.

### Flashing back to stock (restores VIA / Launcher)

Download the official V1 Max firmware from Keychron and flash it the same way
(enter bootloader, flash the Keychron `.bin`):

- Keychron firmware & instructions: <https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-via-wireless-keyboard>
- Keychron Launcher (web VIA): <https://launcher.keychron.com>

After reflashing stock firmware, VIA/Launcher remapping works again.

---

## Files

| File | Purpose |
|------|---------|
| `keymap.c` | layers, custom keycodes, `process_record_user`, `encoder_update_user` |
| `focalpoint.c` | `raw_hid_receive`, protocol state, RGB painting, event senders, Keychron 0xA0–0xAB passthrough |
| `focalpoint.h` | protocol wire constants (command/state/control IDs) |
| `config.h` | keymap config hook (no overrides needed) |
| `rules.mk` | `VIA_ENABLE=no`, `RAW_ENABLE=yes`, swaps in `focalpoint.c` for the stock raw-HID handler |
| `install.sh` | symlink/copy this dir into a Keychron fork checkout |
| `build/` | prebuilt `.bin` + `SHA256SUMS` |
