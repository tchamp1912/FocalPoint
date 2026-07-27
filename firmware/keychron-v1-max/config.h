/* FocalPoint keymap for Keychron V1 Max (ansi_encoder)
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#pragma once

/* The stock Keychron raw HID endpoint already uses QMK's default
 * RAW_USAGE_PAGE 0xFF60 / RAW_USAGE_ID 0x61 and 32-byte reports, which is
 * exactly what PROTOCOL.md 2 and focalpointd require. Nothing to override here;
 * this file exists as the keymap's config hook.
 *
 * FocalPoint keeps the stock VID/PID (Keychron 0x3434 / 0x0913). The daemon
 * matches on usage page and falls back from the canonical 0xFEED/0x5642 to any
 * 0xFF60/0x61 device, so the Keychron IDs are fine.
 */
