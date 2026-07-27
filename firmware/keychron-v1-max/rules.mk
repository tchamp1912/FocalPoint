# FocalPoint keymap for Keychron V1 Max (ansi_encoder)
# SPDX-License-Identifier: GPL-2.0-or-later

# VIA owns the Raw HID endpoint with command IDs that collide with ours, so it
# MUST be disabled for this keymap. Flashing stock Keychron firmware restores
# VIA. (See README.)
VIA_ENABLE = no

# Raw HID transport for the FocalPoint protocol (usage page 0xFF60 / usage 0x61).
# Also enabled data-driven via info.json ("raw": true); set explicitly for
# clarity and in case this keymap is copied to a board without that flag.
RAW_ENABLE = yes

# FocalPoint sources.
SRC += focalpoint.c

# ---------------------------------------------------------------------------
# Drop Keychron's common raw_hid_receive() so ours (in focalpoint.c) is the only
# one. Keychron ships a *strong* raw_hid_receive() in common/keychron_raw_hid.c
# and we re-service its 0xA0..0xAB commands from focalpoint.c, so the file itself
# must leave the build to avoid a duplicate-symbol link error.
#
# The naive `SRC := $(filter-out ...,$(SRC))` does NOT work here: this keymap
# rules.mk is parsed (build_keyboard.mk ~L198) BEFORE the platform makefiles
# (~L480) that define PLATFORM_COMMON_DIR / BOOTLOADER_TYPE. SRC already holds
# deferred entries that use them (platforms/common.mk: hardware_id.c,
# platform.c, suspend.c, timer.c, bootloaders/$(BOOTLOADER_TYPE).c). A `:=`
# force-expands SRC now, baking those to empty paths and silently dropping the
# ChibiOS startup/vectors (symptom: 2-byte .bin, "cannot find entry symbol
# Reset_Handler"). Pre-seeding the platform vars is worse: it perturbs the
# include order and breaks wait.h's __has_include_next("_wait.h") (wait_ms).
#
# Instead, capture SRC's *unexpanded* recursive body with $(value ...) and
# redefine SRC as a recursive (=) variable, so every deferred ref expands
# lazily at use-time (L517), once the platform vars exist. The
# `%keychron_raw_hid.c` wildcard matches regardless of the KEYCHRON_COMMON_DIR
# prefix at that point. Board-agnostic and copy-paste safe.
VK_SRC_BODY := $(value SRC)
SRC = $(filter-out %keychron_raw_hid.c,$(VK_SRC_BODY))
