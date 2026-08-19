#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=packaging/install-lib.sh
source "$ROOT/packaging/install-lib.sh"

SCRATCH="$(mktemp -d /tmp/focalpoint-install-lib.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ADAPTERS="$SCRATCH/adapters"
mkdir -p "$ADAPTERS"
touch "$ADAPTERS/current.sh" "$ADAPTERS/removed.sh" "$ADAPTERS/user-file.sh"
printf '%s\n' current.sh removed.sh > "$ADAPTERS/.focalpoint-installed-files"
prune_manifested_files \
  "$ADAPTERS" "$ADAPTERS/.focalpoint-installed-files" current.sh
test -f "$ADAPTERS/current.sh"
test ! -e "$ADAPTERS/removed.sh"
test -f "$ADAPTERS/user-file.sh"

# A malicious manifest entry must never escape the managed directory.
touch "$SCRATCH/outside"
printf '%s\n' ../outside > "$ADAPTERS/.focalpoint-installed-files"
prune_manifested_files \
  "$ADAPTERS" "$ADAPTERS/.focalpoint-installed-files" current.sh
test -f "$SCRATCH/outside"

ACTIVE="$SCRATCH/active-bin"
STALE="$SCRATCH/stale-bin"
mkdir -p "$ACTIVE" "$STALE"
touch "$STALE/.focalpoint-installed-focalpoint"
ln -s "$STALE/.focalpoint-installed-focalpoint" "$STALE/focalpoint"
touch "$STALE/unrelated"
prune_managed_binary_root \
  "$STALE" "$ACTIVE" "$ROOT/daemon/target" focalpoint
test ! -e "$STALE/focalpoint"
test ! -e "$STALE/.focalpoint-installed-focalpoint"
test -f "$STALE/unrelated"

printf '%s\n' '#!/bin/sh' 'echo Control the FocalPoint macropad' > "$STALE/focalpoint"
chmod +x "$STALE/focalpoint"
printf '%s\n' '#!/bin/sh' 'echo unrelated' > "$STALE/focalpointd"
chmod +x "$STALE/focalpointd"
prune_managed_binary_root \
  "$STALE" "$ACTIVE" "$ROOT/daemon/target" focalpoint focalpointd
test ! -e "$STALE/focalpoint"
test -f "$STALE/focalpointd"

echo "install cleanup tests passed"
