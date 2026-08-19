#!/usr/bin/env bash
# Narrow, reusable cleanup helpers for install.sh. Every deletion is limited
# to a path previously recorded as FocalPoint-owned or to an exact managed
# binary name/target.

prune_manifested_files() {
  local directory="$1" manifest="$2"
  shift 2
  [ -f "$manifest" ] || return 0

  local relative keep current target
  while IFS= read -r relative || [ -n "$relative" ]; do
    # Refuse absolute paths, traversal, and empty entries even if a manifest
    # is corrupted or edited by hand.
    case "$relative" in
      ""|/*|..|../*|*/..|*/../*) continue ;;
    esac
    keep=0
    for current in "$@"; do
      if [ "$relative" = "$current" ]; then
        keep=1
        break
      fi
    done
    [ "$keep" -eq 0 ] || continue
    target="$directory/$relative"
    if [ -e "$target" ] || [ -L "$target" ]; then
      rm -rf -- "$target"
      printf 'removed stale managed file %s\n' "$target"
    fi
  done < "$manifest"
}

write_owned_manifest() {
  local manifest="$1"
  shift
  local temporary="$manifest.tmp.$$"
  printf '%s\n' "$@" > "$temporary"
  mv -f "$temporary" "$manifest"
}

prune_managed_binary_root() {
  local root="$1" active_root="$2" repo_marker="$3"
  shift 3
  [ "$root" != "$active_root" ] || return 0
  [ -d "$root" ] || return 0
  [ -w "$root" ] || {
    printf 'cannot prune stale managed binaries in unwritable %s\n' "$root"
    return 0
  }

  local bin link installed target legacy_marker
  for bin in "$@"; do
    link="$root/$bin"
    installed="$root/.focalpoint-installed-$bin"
    if [ -L "$link" ]; then
      target="$(readlink "$link")"
      case "$target" in
        "$installed"|"$repo_marker"*|*/daemon/target/release/"$bin")
          rm -f -- "$link"
          printf 'removed stale managed link %s\n' "$link"
          ;;
      esac
    fi
    # Very old installations could leave a direct executable rather than a
    # managed link. Prove it is one of our binaries using its exact embedded
    # CLI description before deleting it; a same-named unrelated executable
    # is preserved.
    legacy_marker=""
    case "$bin" in
      focalpoint) legacy_marker="Control the FocalPoint macropad" ;;
      focalpointd) legacy_marker="FocalPoint host daemon" ;;
      fpctl-agent) legacy_marker="Safe FocalPoint orchestration controller" ;;
    esac
    if [ -n "$legacy_marker" ] && [ -f "$link" ] && [ ! -L "$link" ] \
      && [ -x "$link" ] \
      && /usr/bin/strings -a "$link" | /usr/bin/grep -F "$legacy_marker" >/dev/null; then
      rm -f -- "$link"
      printf 'removed stale legacy FocalPoint binary %s\n' "$link"
    fi
    if [ -e "$installed" ] || [ -L "$installed" ]; then
      rm -f -- "$installed"
      printf 'removed stale managed binary %s\n' "$installed"
    fi
  done
}
