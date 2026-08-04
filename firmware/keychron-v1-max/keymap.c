/* FocalPoint keymap for Keychron V1 Max (ansi_encoder)
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Layers 0..3 are the stock Keychron Mac/Win base + Fn layers, unchanged
 * except that tapping left Option/Alt alone arms FocalPoint for one key.
 * Layer 4 (FOCALPOINT) is the held control surface (see README).
 */

#include QMK_KEYBOARD_H
#include "keychron_common.h"
#include "focalpoint.h"

enum layers {
    MAC_BASE,
    MAC_FN,
    WIN_BASE,
    WIN_FN,
    FOCALPOINT,   /* one-shot after a standalone Option/Alt tap */
};

/* Custom keycodes start after Keychron's QK_KB_0 range (NEW_SAFE_RANGE). */
enum focalpoint_keycodes {
    VK_UK1 = NEW_SAFE_RANGE,  /* user key 1  -> control 4  */
    VK_UK2,                   /* user key 2  -> control 5  */
    VK_UK3,
    VK_UK4,
    VK_UK5,
    VK_UK6,
    VK_UK7,
    VK_UK8,
    VK_UK9,
    VK_UK10,
    VK_UK11,
    VK_UK12,                  /* user key 12 -> control 15 */
    VK_ACC,                   /* accept   -> control 0  */
    VK_REJ,                   /* reject   -> control 1  */
    VK_NEW,                   /* new-task -> control 2  */
    VK_PTT,                   /* push-to-talk -> control 3 (press AND release) */
    VK_DIALP,                 /* dial press -> control 16 */
    VK_ATT_NEXT,               /* right arrow -> control 17 */
    VK_ATT_PREV,               /* left arrow -> control 18 */
    VK_SESSION_NEXT,           /* down arrow -> control 19 */
    VK_SESSION_PREV,           /* up arrow -> control 20 */
    VK_FP_MAC_OPTION,          /* normal Option; standalone tap arms FocalPoint */
    VK_FP_WIN_ALT,             /* normal Alt; standalone tap arms FocalPoint */
};

// clang-format off
const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [MAC_BASE] = LAYOUT_ansi_82(
        KC_ESC,   KC_BRID,  KC_BRIU,  KC_MCTRL, KC_LNPAD, RGB_VAD,  RGB_VAI,  KC_MPRV,  KC_MPLY,  KC_MNXT,  KC_MUTE,  KC_VOLD,  KC_VOLU,  KC_DEL,             KC_MUTE,
        KC_GRV,   KC_1,     KC_2,     KC_3,     KC_4,     KC_5,     KC_6,     KC_7,     KC_8,     KC_9,     KC_0,     KC_MINS,  KC_EQL,   KC_BSPC,            KC_PGUP,
        KC_TAB,   KC_Q,     KC_W,     KC_E,     KC_R,     KC_T,     KC_Y,     KC_U,     KC_I,     KC_O,     KC_P,     KC_LBRC,  KC_RBRC,  KC_BSLS,            KC_PGDN,
        KC_CAPS,  KC_A,     KC_S,     KC_D,     KC_F,     KC_G,     KC_H,     KC_J,     KC_K,     KC_L,     KC_SCLN,  KC_QUOT,            KC_ENT,             KC_HOME,
        KC_LSFT,            KC_Z,     KC_X,     KC_C,     KC_V,     KC_B,     KC_N,     KC_M,     KC_COMM,  KC_DOT,   KC_SLSH,            KC_RSFT,  KC_UP,
        KC_LCMMD, VK_FP_MAC_OPTION, KC_LCTL,                        KC_SPC,                                 KC_RCMMD,MO(MAC_FN),KC_LOPTN,     KC_LEFT, KC_DOWN,  KC_RGHT),

    [MAC_FN] = LAYOUT_ansi_82(
        _______,  KC_F1,    KC_F2,    KC_F3,    KC_F4,    KC_F5,    KC_F6,    KC_F7,    KC_F8,    KC_F9,    KC_F10,   KC_F11,   KC_F12,   _______,            RGB_TOG,
        _______,  BT_HST1,  BT_HST2,  BT_HST3,  P2P4G,    _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,
        RGB_TOG,  RGB_MOD,  RGB_VAI,  RGB_HUI,  RGB_SAI,  RGB_SPI,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,
        _______,  RGB_RMOD, RGB_VAD,  RGB_HUD,  RGB_SAD,  RGB_SPD,  _______,  _______,  _______,  _______,  _______,  _______,            _______,            KC_END,
        _______,            _______,  _______,  _______,  _______,  BAT_LVL,  NK_TOGG,  _______,  _______,  _______,  _______,            _______,  _______,
        _______,  _______,  _______,                                _______,                                _______,  _______,  _______,  _______,  _______,  _______),

    [WIN_BASE] = LAYOUT_ansi_82(
        KC_ESC,   KC_F1,    KC_F2,    KC_F3,    KC_F4,    KC_F5,    KC_F6,    KC_F7,    KC_F8,    KC_F9,    KC_F10,   KC_F11,   KC_F12,   KC_DEL,             KC_MUTE,
        KC_GRV,   KC_1,     KC_2,     KC_3,     KC_4,     KC_5,     KC_6,     KC_7,     KC_8,     KC_9,     KC_0,     KC_MINS,  KC_EQL,   KC_BSPC,            KC_PGUP,
        KC_TAB,   KC_Q,     KC_W,     KC_E,     KC_R,     KC_T,     KC_Y,     KC_U,     KC_I,     KC_O,     KC_P,     KC_LBRC,  KC_RBRC,  KC_BSLS,            KC_PGDN,
        KC_CAPS,  KC_A,     KC_S,     KC_D,     KC_F,     KC_G,     KC_H,     KC_J,     KC_K,     KC_L,     KC_SCLN,  KC_QUOT,            KC_ENT,             KC_HOME,
        KC_LSFT,            KC_Z,     KC_X,     KC_C,     KC_V,     KC_B,     KC_N,     KC_M,     KC_COMM,  KC_DOT,   KC_SLSH,            KC_RSFT,  KC_UP,
        KC_LCTL,  KC_LGUI,  VK_FP_WIN_ALT,                          KC_SPC,                                 KC_RALT, MO(WIN_FN),KC_LALT,      KC_LEFT, KC_DOWN,  KC_RGHT),

    [WIN_FN] = LAYOUT_ansi_82(
        _______,  KC_BRID,  KC_BRIU,  KC_TASK,  KC_FILE,  RGB_VAD,  RGB_VAI,  KC_MPRV,  KC_MPLY,  KC_MNXT,  KC_MUTE,  KC_VOLD,  KC_VOLU,  _______,            RGB_TOG,
        _______,  BT_HST1,  BT_HST2,  BT_HST3,  P2P4G,    _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,
        RGB_TOG,  RGB_MOD,  RGB_VAI,  RGB_HUI,  RGB_SAI,  RGB_SPI,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,
        _______,  RGB_RMOD, RGB_VAD,  RGB_HUD,  RGB_SAD,  RGB_SPD,  _______,  _______,  _______,  _______,  _______,  _______,            _______,            KC_END,
        _______,            _______,  _______,  _______,  _______,  BAT_LVL,  NK_TOGG,  _______,  _______,  _______,  _______,            _______,  _______,
        _______,  _______,  _______,                                _______,                                _______,  _______,  _______,  _______,  _______,  _______),

    /* FocalPoint control surface (held). Unmapped keys are transparent so the
     * board keeps typing normally while the layer is held. */
    [FOCALPOINT] = LAYOUT_ansi_82(
        _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            VK_DIALP,
        _______,  VK_UK1,   VK_UK2,   VK_UK3,   VK_UK4,   VK_UK5,   VK_UK6,   VK_UK7,   VK_UK8,   VK_UK9,   VK_UK10,  VK_UK11,  VK_UK12,  _______,            _______,
        _______,  _______,  _______,  _______,  VK_REJ,   _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,
        _______,  VK_ACC,   _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,  _______,            _______,            _______,
        _______,            _______,  _______,  _______,  _______,  _______,  VK_NEW,   _______,  _______,  _______,  _______,            _______,  VK_SESSION_PREV,
        _______,  VK_FP_MAC_OPTION, VK_FP_WIN_ALT,                  VK_PTT,                                 _______,  _______,  _______,  VK_ATT_PREV, VK_SESSION_NEXT, VK_ATT_NEXT),
};

// clang-format on
#if defined(ENCODER_MAP_ENABLE)
const uint16_t PROGMEM encoder_map[][NUM_ENCODERS][2] = {
    [MAC_BASE] = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [MAC_FN]   = {ENCODER_CCW_CW(RGB_VAD, RGB_VAI)},
    [WIN_BASE] = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
    [WIN_FN]   = {ENCODER_CCW_CW(RGB_VAD, RGB_VAI)},
    /* Fallback when the FocalPoint layer is held but no daemon is attached:
     * knob still does volume. When host mode is on, encoder_update_user
     * intercepts and sends DIAL instead (returns false below). */
    [FOCALPOINT]  = {ENCODER_CCW_CW(KC_VOLD, KC_VOLU)},
};
#endif

/* Map a FocalPoint keycode to its protocol control id, or 0xFF if not ours. */
static uint8_t vk_control_for(uint16_t keycode) {
    switch (keycode) {
        case VK_UK1 ... VK_UK12: return VK_CTRL_USER_1 + (keycode - VK_UK1);
        case VK_ACC:             return VK_CTRL_ACCEPT;
        case VK_REJ:             return VK_CTRL_REJECT;
        case VK_NEW:             return VK_CTRL_NEW_TASK;
        case VK_PTT:             return VK_CTRL_PTT;
        case VK_DIALP:           return VK_CTRL_DIAL_PRESS;
        case VK_ATT_NEXT:        return VK_CTRL_ATTENTION_NEXT;
        case VK_ATT_PREV:        return VK_CTRL_ATTENTION_PREV;
        case VK_SESSION_NEXT:    return VK_CTRL_SESSION_NEXT;
        case VK_SESSION_PREV:    return VK_CTRL_SESSION_PREV;
        default:                 return 0xFF;
    }
}

static bool vk_option_down;
static bool vk_option_used_as_modifier;
static bool vk_focalpoint_armed;
static bool vk_focalpoint_control_down;
static uint16_t vk_focalpoint_armed_at;

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    /* Option/Alt must remain a true OS modifier: it is frequently used for
     * application hotkeys. A standalone tap arms one FocalPoint command after
     * release; pressing any other key while held is an ordinary Option/Alt
     * chord and never enables the FocalPoint layer. */
    if (keycode == VK_FP_MAC_OPTION || keycode == VK_FP_WIN_ALT) {
        uint16_t modifier = keycode == VK_FP_MAC_OPTION ? KC_LOPTN : KC_LALT;
        if (record->event.pressed) {
            register_code16(modifier);
            vk_option_down = true;
            vk_option_used_as_modifier = false;
        } else {
            unregister_code16(modifier);
            if (vk_option_down && !vk_option_used_as_modifier && vk_host_mode_on()) {
                layer_on(FOCALPOINT);
                vk_focalpoint_armed = true;
                vk_focalpoint_armed_at = timer_read();
            }
            vk_option_down = false;
        }
        return false;
    }

    if (vk_option_down && record->event.pressed) vk_option_used_as_modifier = true;

    uint8_t control = vk_control_for(keycode);
    if (vk_focalpoint_armed && record->event.pressed && control == 0xFF) {
        /* A non-control key consumes the one-shot layer transparently. */
        layer_off(FOCALPOINT);
        vk_focalpoint_armed = false;
    }
    if (control != 0xFF) {
        /* FocalPoint control key. When a daemon is attached (host mode on) emit a
         * HID event and never a keystroke; when detached, act as a no-op. */
        if (vk_host_mode_on()) {
            vk_send_key_event(control, record->event.pressed);
        }
        if (vk_focalpoint_armed) {
            if (record->event.pressed) vk_focalpoint_control_down = true;
            else if (vk_focalpoint_control_down) {
                layer_off(FOCALPOINT);
                vk_focalpoint_armed = false;
                vk_focalpoint_control_down = false;
            }
        }
        return false;  /* consume: never types */
    }

    /* Everything else: preserve Keychron's media / BT / RGB Fn keycodes. */
    if (!process_record_keychron_common(keycode, record)) {
        return false;
    }
    return true;
}

void matrix_scan_user(void) {
    /* Avoid leaving a surprising control layer armed after an accidental tap. */
    if (vk_focalpoint_armed && !vk_focalpoint_control_down
        && timer_elapsed(vk_focalpoint_armed_at) > 1000) {
            layer_off(FOCALPOINT);
            vk_focalpoint_armed = false;
    }
}

#if defined(ENCODER_ENABLE)
bool encoder_update_user(uint8_t index, bool clockwise) {
    if (index == 0 && vk_host_mode_on() && layer_state_is(FOCALPOINT)) {
        vk_send_dial(clockwise ? 1 : -1);
        return false;  /* consume: suppress the volume encoder_map entry */
    }
    return true;       /* let encoder_map handle it (volume / RGB) */
}
#endif
