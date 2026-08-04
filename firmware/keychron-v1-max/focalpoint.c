/* FocalPoint firmware for Keychron V1 Max (ansi_encoder)
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Implements the device side of the FocalPoint Raw HID protocol and the RGB
 * status painting.  See PROTOCOL.md sections 1 and 2.
 *
 * Raw HID ownership
 * -----------------
 * Keychron's firmware ships a strong raw_hid_receive() in
 *   keyboards/keychron/common/keychron_raw_hid.c
 * whose command IDs are all 0xA0..0xAB (Keychron Launcher / wireless config /
 * factory test / BT-module DFU).  FocalPoint uses 0x00..0x04, so the *command
 * space* does not collide, but two strong raw_hid_receive() definitions do.
 *
 * This keymap's rules.mk filters that file out of SRC and this file provides
 * the single raw_hid_receive().  We still service the Keychron 0xA0..0xAB
 * commands by delegating to the helper functions that live in the other
 * (still-compiled) Keychron common source files, so Keychron Launcher and the
 * wireless stack keep working.  Nothing outside keychron_raw_hid.c referenced
 * its internal symbols, so removing it is safe.
 */

#include QMK_KEYBOARD_H
#include "raw_hid.h"
#include "focalpoint.h"

/* Keychron passthrough dependencies (0xA0..0xAB) */
#include "keychron_raw_hid.h"
#include "version.h"
#include "language.h"
#ifdef FACTORY_TEST_ENABLE
#    include "factory_test.h"
#endif
#ifdef LK_WIRELESS_ENABLE
#    include "lkbt51.h"
#    include "wireless.h"
#endif

/* Raw HID report size (QMK default 32, per PROTOCOL.md 2). */
#ifndef RAW_EPSIZE
#    define RAW_EPSIZE 32
#endif

/* Scale v (0..255) by s (0..255); s=255 ~= identity. Avoids depending on
 * lib8tion's scale8 being on the include path. */
static inline uint8_t vk_scale(uint8_t v, uint8_t s) {
    return (uint8_t)(((uint16_t)v * (uint16_t)s) >> 8);
}

/* =======================================================================
 * State
 * ======================================================================= */

static bool    vk_host_mode          = false;               /* default off  */
static uint8_t vk_aggregate          = VK_STATE_IDLE;       /* Esc          */
static uint8_t vk_key_state[VK_USER_KEY_COUNT];             /* slots 1..12  */
static uint8_t vk_next_attention     = VK_STATE_EMPTY;      /* Right arrow  */

typedef struct {
    uint8_t r, g, b, pattern;
    uint16_t period_ms;
} vk_style_t;
static vk_style_t vk_styles[VK_STATE_COMPACTING + 1];

typedef struct {
    bool    active;
    uint8_t r, g, b;
} vk_led_override_t;
static vk_led_override_t vk_override[VK_USER_KEY_COUNT];    /* SET_LED      */

/* LED indices derived from the board's g_led_config (see README table).
 * Session keys 1..12 are the number-row keys 1 2 3 4 5 6 7 8 9 0 - =
 * which are LED indices 15..26.  Esc is LED index 0. */
#define VK_LED_SESSION_BASE 15   /* LED index of user-key 1 ("1")           */
#define VK_LED_ESC          0    /* LED index of Esc (aggregate indicator)  */
/* The final LED in the V1 Max ANSI matrix is the physical Right Arrow. */
#define VK_LED_RIGHT_ARROW  81

static inline uint8_t vk_slot_led(uint8_t slot0) { /* slot0: 0..11 */
    return VK_LED_SESSION_BASE + slot0;
}

static void vk_clear_overrides(void) {
    for (uint8_t i = 0; i < VK_USER_KEY_COUNT; i++) vk_override[i].active = false;
}

bool vk_host_mode_on(void) { return vk_host_mode; }

/* =======================================================================
 * Device -> host events
 * ======================================================================= */

/* Host mode can only be turned on by a daemon, and a daemon can only reach us
 * over the USB Raw HID endpoint, so vk_host_mode implies a live USB connection.
 * (The V1 Max keeps USB enumerated even in wireless mode, so the daemon works
 * over the cable regardless of which transport keystrokes use.) host_mode is
 * cleared on USB suspend/reset, so we never push into a dead endpoint. */
static bool vk_can_send(void) {
    return vk_host_mode;
}

static void vk_send(uint8_t cmd, uint8_t b1, uint8_t b2) {
    uint8_t report[RAW_EPSIZE];
    memset(report, 0, sizeof(report));
    report[0] = cmd;
    report[1] = b1;
    report[2] = b2;
    raw_hid_send(report, sizeof(report));
}

void vk_send_key_event(uint8_t control_id, bool pressed) {
    if (!vk_can_send()) return;
    vk_send(VK_CMD_KEY_EVENT, control_id, pressed ? 1 : 0);
}

void vk_send_dial(int8_t delta) {
    if (!vk_can_send()) return;
    vk_send(VK_CMD_DIAL, (uint8_t)delta, 0);
}

/* =======================================================================
 * Keychron 0xA0..0xAB passthrough
 * (faithful reproduction of kc_raw_hid_rx from keychron_raw_hid.c)
 * ======================================================================= */

extern void dfu_info_rx(uint8_t *data, uint8_t length);

__attribute__((weak)) void kc_rgb_matrix_rx(uint8_t *data, uint8_t length) {}

static void vk_get_support_feature(uint8_t *data) {
    data[0] = 0;
    data[1] = FEATURE_DEFAULT_LAYER
#ifdef LK_WIRELESS_ENABLE
              | FEATURE_BLUETOOTH | FEATURE_P24G
#endif
#ifdef KEYCHRON_RGB_ENABLE
              | FEATURE_KEYCHRON_RGB
#endif
        ;
}

static void vk_get_firmware_version(uint8_t *data) {
    uint8_t i = 0;
    data[i++] = 'v';
    if ((DEVICE_VER & 0xF000) != 0) itoa((DEVICE_VER >> 12), (char *)&data[i++], 16);
    itoa((DEVICE_VER >> 8) & 0xF, (char *)&data[i++], 16);
    data[i++] = '.';
    itoa((DEVICE_VER >> 4) & 0xF, (char *)&data[i++], 16);
    data[i++] = '.';
    itoa(DEVICE_VER & 0xF, (char *)&data[i++], 16);
    data[i++] = ' ';
    memcpy(&data[i], QMK_BUILDDATE, sizeof(QMK_BUILDDATE));
    i += sizeof(QMK_BUILDDATE);
}

/* Returns true if it handled the command (and already replied). */
static bool vk_keychron_passthrough(uint8_t *data, uint8_t length) {
    switch (data[0]) {
        case KC_GET_PROTOCOL_VERSION:
            data[1] = PROTOCOL_VERSION;
            data[2] = 0;
            data[3] = QMK_COMMAND_SET;
            break;

        case KC_GET_FIRMWARE_VERSION:
            vk_get_firmware_version(&data[1]);
            break;

        case KC_GET_SUPPORT_FEATURE:
            vk_get_support_feature(&data[1]);
            break;

        case KC_GET_DEFAULT_LAYER:
            data[1] = get_highest_layer(default_layer_state);
            break;

        case 0xA7:
            switch (data[1]) {
                case MISC_GET_PROTOCOL_VER:
                    data[2] = 0;
                    data[3] = MISC_PROTOCOL_VERSION & 0xFF;
                    data[4] = (MISC_PROTOCOL_VERSION >> 8) & 0xFF;
                    data[5] = MISC_DFU_INFO | MISC_LANGUAGE
#ifdef LK_WIRELESS_ENABLE
                            | MISC_WIRELESS_LPM
#endif
                            ;
                    break;
                case DFU_INFO_GET:
                    dfu_info_rx(data, length);
                    break;
                case LANGUAGE_GET ... LANGUAGE_SET:
                    language_rx(data, length);
                    break;
#if defined(LK_WIRELESS_ENABLE) && defined(EECONFIG_BASE_WIRELESS_CONFIG)
                case WIRELESS_LPM_GET ... WIRELESS_LPM_SET:
                    wireless_raw_hid_rx(data, length);
                    break;
#endif
                default:
                    data[0] = 0xFF;
                    data[1] = 0;
                    break;
            }
            break;

#if defined(KEYCHRON_RGB_ENABLE)
        case 0xA8:
            kc_rgb_matrix_rx(data, length);
            break;
#endif
#ifdef LK_WIRELESS_ENABLE
        case 0xAA:
            lkbt51_dfu_rx(data, length);
            return true;
#endif
#ifdef FACTORY_TEST_ENABLE
        case 0xAB:
            factory_test_rx(data, length);
            return true;
#endif
        default:
            return false;
    }

    raw_hid_send(data, length);
    return true;
}

/* =======================================================================
 * raw_hid_receive - single entry point for the 0xFF60/0x61 endpoint
 * ======================================================================= */

void raw_hid_receive(uint8_t *data, uint8_t length) {
    switch (data[0]) {
        case VK_CMD_PING: {
            /* PONG: major, minor, key count */
            uint8_t report[RAW_EPSIZE];
            memset(report, 0, sizeof(report));
            report[0] = VK_CMD_PONG;
            report[1] = VK_PROTO_MAJOR;
            report[2] = VK_PROTO_MINOR;
            report[3] = VK_USER_KEY_COUNT;
            raw_hid_send(report, sizeof(report));
            return;
        }

        case VK_CMD_SET_STATE:
            vk_aggregate = data[1];
            /* A new aggregate clears any transient SET_LED overrides
             * (PROTOCOL.md: SET_LED "overrides effect until next SET_STATE"). */
            vk_clear_overrides();
            return;

        case VK_CMD_SET_LED: {
            uint8_t idx = data[1];
            uint8_t r = data[2], g = data[3], b = data[4];
            if (idx == 0xFF) {
                for (uint8_t i = 0; i < VK_USER_KEY_COUNT; i++) {
                    vk_override[i].active = true;
                    vk_override[i].r = r; vk_override[i].g = g; vk_override[i].b = b;
                }
            } else if (idx >= 1 && idx <= VK_USER_KEY_COUNT) {
                vk_override[idx - 1].active = true;
                vk_override[idx - 1].r = r;
                vk_override[idx - 1].g = g;
                vk_override[idx - 1].b = b;
            }
            return;
        }

        case VK_CMD_SET_HOST_MODE:
            vk_host_mode = (data[1] != 0);
            return;

        case VK_CMD_SET_KEY_STATE: {
            uint8_t slot = data[1];  /* 1..12 */
            if (slot >= 1 && slot <= VK_USER_KEY_COUNT) {
                vk_key_state[slot - 1] = data[2];  /* state id or 0xFF empty */
            }
            return;
        }

        case VK_CMD_SET_STATE_STYLE:
            if (data[1] <= VK_STATE_COMPACTING && data[5] <= 4) {
                vk_styles[data[1]].r = data[2];
                vk_styles[data[1]].g = data[3];
                vk_styles[data[1]].b = data[4];
                vk_styles[data[1]].pattern = data[5];
                vk_styles[data[1]].period_ms = (uint16_t)data[6] | ((uint16_t)data[7] << 8);
                if (vk_styles[data[1]].period_ms < 100) vk_styles[data[1]].period_ms = 100;
            }
            return;

        case VK_CMD_SET_NAV_STATE:
            vk_next_attention = data[1];
            return;

        default:
            /* Not a FocalPoint command: hand to the Keychron responder. */
            vk_keychron_passthrough(data, length);
            return;
    }
}

/* =======================================================================
 * USB reset / suspend: revert to detached (PROTOCOL.md 2)
 * ======================================================================= */

void suspend_power_down_user(void) {
    vk_host_mode = false;
}

/* =======================================================================
 * RGB status painting
 * ======================================================================= */
#ifdef RGB_MATRIX_ENABLE

/* ~2 s triangle wave, 0..255, for breathing effects. */
/* Paint one state on one LED index (already known to be in [min,max)).
 * aggregate=true means the Esc indicator, where idle paints nothing. */
static void vk_paint_state(uint8_t idx, uint8_t state, bool aggregate) {
    if (state > VK_STATE_COMPACTING || (aggregate && (state == VK_STATE_IDLE || state == VK_STATE_COMPACTING))) return;
    vk_style_t style = vk_styles[state];
    if (style.pattern == 4) return;
    uint8_t r = style.r, g = style.g, b = style.b;
    uint16_t period = style.period_ms ? style.period_ms : 1000;
    uint16_t phase = timer_read32() % period;
    if (style.pattern == 1) { /* breathe */
        uint8_t level = phase < period / 2 ? (uint32_t)phase * 255 / (period / 2) : (uint32_t)(period - phase) * 255 / (period - period / 2);
        r = vk_scale(r, level); g = vk_scale(g, level); b = vk_scale(b, level);
    } else if (style.pattern == 2 && phase >= period / 2) { /* blink */
        r = g = b = 0;
    } else if (style.pattern == 3 && phase >= period / 8) { /* strobe */
        r = g = b = 0;
    }
    rgb_matrix_set_color(idx, r, g, b);
}

bool rgb_matrix_indicators_advanced_user(uint8_t led_min, uint8_t led_max) {
    if (!vk_host_mode) return true;
    /* QMK may invoke the advanced callback in LED ranges. Do not merely paint
     * its current range: the keyboard effect can otherwise leave a travelling
     * wave in a range that has not been visited yet. FocalPoint owns the whole
     * frame while attached, repainting a black overlay across every LED before
     * restoring its tiny set of indicators. */
    (void)led_min;
    (void)led_max;
    for (uint8_t idx = 0; idx < DRIVER_LED_TOTAL; idx++) rgb_matrix_set_color(idx, 0, 0, 0);

    /* Esc = aggregate state (idle paints nothing). */
    vk_paint_state(VK_LED_ESC, vk_aggregate, true);

    /* Number row = session slots 1..12. */
    for (uint8_t i = 0; i < VK_USER_KEY_COUNT; i++) {
        uint8_t idx = vk_slot_led(i);
        if (vk_override[i].active) {       /* SET_LED override wins */
            rgb_matrix_set_color(idx, vk_override[i].r, vk_override[i].g, vk_override[i].b);
        } else if (vk_key_state[i] != VK_STATE_EMPTY) {
            vk_paint_state(idx, vk_key_state[i], false);
        }
        /* else: stays black in the full FocalPoint overlay */
    }
    if (vk_next_attention != VK_STATE_EMPTY) {
        vk_paint_state(VK_LED_RIGHT_ARROW, vk_next_attention, false);
    }
    return true;
}
#endif /* RGB_MATRIX_ENABLE */

/* =======================================================================
 * Init: start empty so a fresh boot is a plain keyboard.
 * ======================================================================= */
void keyboard_post_init_user(void) {
    for (uint8_t i = 0; i < VK_USER_KEY_COUNT; i++) {
        vk_key_state[i]     = VK_STATE_EMPTY;
        vk_override[i].active = false;
    }
    vk_aggregate = VK_STATE_IDLE;
    vk_next_attention = VK_STATE_EMPTY;
    const vk_style_t defaults[] = {
        {40, 40, 40, 1, 4000}, {158, 89, 242, 1, 2500},
        {255, 166, 26, 1, 800}, {64, 140, 255, 2, 800},
        {51, 204, 89, 0, 1000}, {242, 64, 64, 2, 250},
        {110, 110, 140, 1, 3000},
    };
    memcpy(vk_styles, defaults, sizeof(vk_styles));
    vk_host_mode = false;
}
