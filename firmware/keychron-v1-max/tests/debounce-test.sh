#!/usr/bin/env bash
# Exercise the real QMK debouncer using simulated switch chatter, no keyboard needed.
# Usage: bash tests/debounce-test.sh /path/to/keychron-qmk
set -euo pipefail
qmk_root="${1:?Pass a Keychron QMK checkout}"
keymap_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/debounce.h" <<'HEADER'
#include <stdint.h>
#include <stdbool.h>
typedef uint16_t matrix_row_t;
#define MATRIX_COLS 2
void debounce_init(uint8_t rows);
void debounce_free(void);
bool debounce(matrix_row_t raw[], matrix_row_t cooked[], uint8_t rows, bool changed);
HEADER
cat > "$test_dir/timer.h" <<'HEADER'
#include <stdint.h>
typedef uint16_t fast_timer_t;
extern uint16_t test_time;
#define timer_read_fast() test_time
#define TIMER_DIFF_FAST(a, b) ((uint16_t)((a) - (b)))
HEADER
cat > "$test_dir/test.c" <<'SOURCE'
#include "debounce.h"
#include <assert.h>
#include <stdio.h>
uint16_t test_time;
int main(void) {
    matrix_row_t raw[1] = {0}, cooked[1] = {0};
    unsigned presses[2] = {0}, releases[2] = {0};
    debounce_init(1);
    for (test_time = 0; test_time < 160; ++test_time) {
        matrix_row_t previous_raw = raw[0], previous_cooked = cooked[0];
        // Key 0: chatter on initial press and release, then an intentional second tap.
        bool first = (test_time >= 10 && test_time < 12)
                  || (test_time >= 14 && test_time < 16)
                  || (test_time >= 18 && test_time < 60)
                  || (test_time >= 62 && test_time < 64)
                  || (test_time >= 66 && test_time < 68)
                  || (test_time >= 100 && test_time < 120);
        // Key 1 overlaps key 0's chatter: per-key timing must remain independent.
        bool second = test_time >= 15 && test_time < 80;
        raw[0] = first | (second << 1);
        bool changed = debounce(raw, cooked, 1, raw[0] != previous_raw);
        assert(changed == (cooked[0] != previous_cooked));
        for (unsigned k = 0; k < 2; ++k) {
            if ((cooked[0] ^ previous_cooked) & (1u << k)) {
                if (cooked[0] & (1u << k)) ++presses[k];
                else ++releases[k];
            }
        }
        if (test_time == 24) assert(cooked[0] == 0);
        if (test_time == 25) assert(cooked[0] == 2);
        if (test_time == 28) assert(cooked[0] == 3);
        if (test_time == 77) assert(cooked[0] == 3);
        if (test_time == 78) assert(cooked[0] == 2);
    }
    assert(presses[0] == 2 && releases[0] == 2);
    assert(presses[1] == 1 && releases[1] == 1);
    assert(cooked[0] == 0);
    debounce_free();
    puts("PASS: press/release chatter filtered; overlapping keys and intentional repeat preserved");
}
SOURCE
cc -std=c11 -Wall -Wextra -Werror -I "$test_dir" \
    -include "$keymap_root/config.h" \
    "$qmk_root/quantum/debounce/sym_defer_pk.c" "$test_dir/test.c" \
    -o "$test_dir/debounce-test"
"$test_dir/debounce-test"
