/* FocalPoint firmware for Keychron V1 Max (ansi_encoder)
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Device-side of the FocalPoint Raw HID protocol (see PROTOCOL.md).
 * This header is the single source of truth for the wire constants; it is
 * kept byte-for-byte in sync with PROTOCOL.md sections 1 and 2.
 */
#pragma once

#include <stdint.h>
#include <stdbool.h>

/* ---- Protocol version reported in PONG ----
 * PROTOCOL.md is at v0.2 and this firmware implements its semantics
 * (including the v0.2 `compacting` state id below), but PONG still reports
 * 0.1: v0.2 was purely additive, no current host gates behavior on the
 * minor, and bumping VK_PROTO_MINOR is a code/behavior change tracked
 * separately from this comment-level doc fix. */
#define VK_PROTO_MAJOR 0
#define VK_PROTO_MINOR 2

/* Number of user keys the firmware exposes (session slots 1..12). Reported
 * as byte 3 of PONG. */
#define VK_USER_KEY_COUNT 12

/* ---- Host -> device command IDs (PROTOCOL.md 2, "Host -> device") ---- */
enum vk_host_cmd {
    VK_CMD_PING          = 0x00, /* b1: proto major, b2: proto minor */
    VK_CMD_SET_STATE     = 0x01, /* b1: aggregate state id           */
    VK_CMD_SET_LED       = 0x02, /* b1: index (0xFF=all), b2..4: RGB  */
    VK_CMD_SET_HOST_MODE = 0x03, /* b1: 1=attached, 0=detached        */
    VK_CMD_SET_KEY_STATE = 0x04, /* b1: user-key 1..12, b2: state/0xFF */
    VK_CMD_SET_STATE_STYLE = 0x05, /* b1: state, b2..4 RGB, b5 pattern, b6..7 period */
    VK_CMD_SET_NAV_STATE = 0x06, /* b1: next-attention state or 0xFF */
};

/* ---- Device -> host command IDs (PROTOCOL.md 2, "Device -> host") ---- */
enum vk_dev_cmd {
    VK_CMD_PONG      = 0x80, /* b1: major, b2: minor, b3: key count */
    VK_CMD_KEY_EVENT = 0x81, /* b1: control id, b2: 1=pressed 0=rel */
    VK_CMD_DIAL      = 0x82, /* b1: signed int8 delta (cw positive) */
    VK_CMD_JOY       = 0x83, /* (never emitted on this hardware)    */
};

/* ---- Agent state IDs (PROTOCOL.md 1) ---- */
enum vk_state {
    VK_STATE_IDLE       = 0,
    VK_STATE_THINKING   = 1,
    VK_STATE_RUNNING    = 2,
    VK_STATE_WAITING    = 3,
    VK_STATE_DONE       = 4,
    VK_STATE_ERROR      = 5,
    /* Transient: a session between identities across a Claude Code
     * compaction (PROTOCOL.md 1/3). Added additively in protocol v0.2 —
     * older hosts never send it, so firmware from before this id existed
     * simply never receives it. */
    VK_STATE_COMPACTING = 6,
};

/* Sentinel for an empty session slot (SET_KEY_STATE b2 == 0xFF). */
#define VK_STATE_EMPTY 0xFF

/* ---- Control IDs (byte 1 of KEY_EVENT, PROTOCOL.md 2 "Control IDs") ---- */
enum vk_control {
    VK_CTRL_ACCEPT    = 0,
    VK_CTRL_REJECT    = 1,
    VK_CTRL_NEW_TASK  = 2,
    VK_CTRL_PTT       = 3,   /* push-to-talk: sends press AND release */
    VK_CTRL_USER_1    = 4,   /* user keys 1..12 -> ids 4..15          */
    /* VK_CTRL_USER_12 == 15 */
    VK_CTRL_DIAL_PRESS = 16,
    VK_CTRL_ATTENTION_NEXT = 17,
    VK_CTRL_ATTENTION_PREV = 18,
    VK_CTRL_SESSION_NEXT = 19,
    VK_CTRL_SESSION_PREV = 20,
};

/* ---- API used by keymap.c ---- */

/* True while a daemon has sent SET_HOST_MODE 1 (only possible over USB). */
bool vk_host_mode_on(void);

/* Emit a KEY_EVENT for a control id (no-op unless host mode is on). */
void vk_send_key_event(uint8_t control_id, bool pressed);

/* Emit a DIAL event (no-op unless host mode is on). */
void vk_send_dial(int8_t delta);
