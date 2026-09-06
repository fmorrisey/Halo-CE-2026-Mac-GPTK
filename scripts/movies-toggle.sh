#!/usr/bin/env bash
#
# movies-toggle.sh — enable/disable UE movie playback by renaming files.
#
# WHY: on this wrapper, Wine's GStreamer/Electra media pipeline wedges when
# playing the game's .mp4 cinematics — "vtdechw2:src" spins forever in
# gst_vtdec_output_loop while every other thread parks, so the engine never
# gets end-of-stream and the load never finishes. Renaming the movies out of
# the way makes UE skip them. See docs/EVIDENCE.md.
#
# Renames  *.mp4  <->  *.mp4.disabled  (extension match is case-insensitive).
# Idempotent: running "off" twice is a no-op. Safe with spaces in paths.
#
# USAGE
#   movies-toggle.sh status                  # report counts per group
#   movies-toggle.sh off [group]             # disable (rename to .disabled)
#   movies-toggle.sh on  [group]             # re-enable
#   movies-toggle.sh off cinematics --dry-run
#
#   group: all (default) | logos | mainmenu | cinematics
#
# CONFIG
#   GAME_CONTENT_DIR  Path to the game's Content directory. If unset, it is
#                     derived from WRAPPER_APP by searching the prefix.
#
#   Worked example from the development machine:
#     WRAPPER_APP="/Applications/Ported Games/Halo CE 2026.app"
#     -> .../drive_c/Program Files (x86)/Steam/steamapps/common/\
#          Halo Campaign Evolved/Meteorite/Content
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ACTION="${1:-status}"; shift || true
GROUP="all"; DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    all|logos|mainmenu|cinematics) GROUP="$a" ;;
    *) die "unknown argument: $a" ;;
  esac
done
case "$ACTION" in on|off|status) ;; *) die "usage: $(basename "$0") {on|off|status} [all|logos|mainmenu|cinematics] [--dry-run]" ;; esac

# --- locate the Content/Movies root ----------------------------------------
find_movies_root() {
  if [ -n "${GAME_CONTENT_DIR:-}" ]; then
    printf '%s/Movies' "$GAME_CONTENT_DIR"; return
  fi
  require_wrapper
  local hit
  hit=$(find "$(prefix_root)/drive_c" -maxdepth 8 -type d -name Movies \
          -path '*/Content/Movies' 2>/dev/null | head -1)
  [ -n "$hit" ] || die "could not find Content/Movies under the wrapper prefix.
  Set GAME_CONTENT_DIR to the game's Content directory, e.g.
    export GAME_CONTENT_DIR=\"\$WRAPPER_APP/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/<Game>/<Project>/Content\""
  printf '%s' "$hit"
}

MOVIES="$(find_movies_root)"
[ -d "$MOVIES" ] || die "movies directory does not exist: $MOVIES"

# Group -> (label, subpath, recursive?)
# LogoParade and MainMenu_Background are flat; CinematicsPreRenders has ~56
# per-scene subdirectories and MUST be walked recursively.
group_dirs() {
  case "$1" in
    logos)      printf '%s\t%s\t%s\n' "LogoParade (Movies root)" "."                      "flat" ;;
    mainmenu)   printf '%s\t%s\t%s\n' "MainMenu_Background"      "MainMenu_Background"     "flat" ;;
    cinematics) printf '%s\t%s\t%s\n' "CinematicsPreRenders"     "CinematicsPreRenders"    "deep" ;;
    all)        group_dirs logos; group_dirs mainmenu; group_dirs cinematics ;;
  esac
}

# Emit NUL-separated matching files for one group entry.
list_files() { # $1=subpath $2=flat|deep $3=enabled|disabled
  local sub="$1" dir depth=() pat
  # "." is the sentinel for "the Movies root itself".
  if [ "$sub" = "." ] || [ -z "$sub" ]; then dir="$MOVIES"; else dir="$MOVIES/$sub"; fi
  [ -d "$dir" ] || return 0
  [ "$2" = "flat" ] && depth=(-maxdepth 1)
  if [ "$3" = "enabled" ]; then pat='*.mp4'; else pat='*.mp4.disabled'; fi
  # -iname gives case-insensitive extension matching (.MP4, .Mp4, ...).
  if [ "$3" = "enabled" ]; then
    find "$dir" ${depth[@]+"${depth[@]}"} -type f -iname "$pat" ! -iname '*.disabled' -print0 2>/dev/null
  else
    find "$dir" ${depth[@]+"${depth[@]}"} -type f -iname "$pat" -print0 2>/dev/null
  fi
}

count_files() { local n=0; while IFS= read -r -d '' _; do n=$((n+1)); done < <(list_files "$1" "$2" "$3"); printf '%s' "$n"; }

# --- status ----------------------------------------------------------------
do_status() {
  info "Movies root: $MOVIES"
  info ""
  printf '  %-28s %9s %9s   %s\n' "GROUP" "ENABLED" "DISABLED" "STATE"
  printf '  %-28s %9s %9s   %s\n' "----------------------------" "-------" "--------" "-----"
  local te=0 td=0
  while IFS=$'\t' read -r label sub mode; do
    [ -n "$label" ] || continue
    local e d state
    e=$(count_files "$sub" "$mode" enabled)
    d=$(count_files "$sub" "$mode" disabled)
    te=$((te+e)); td=$((td+d))
    if   [ "$e" -gt 0 ] && [ "$d" -gt 0 ]; then state="${C_YEL}MIXED${C_RST}"
    elif [ "$e" -gt 0 ];                   then state="${C_GRN}ON${C_RST}"
    elif [ "$d" -gt 0 ];                   then state="${C_DIM}OFF${C_RST}"
    else                                        state="${C_DIM}(no files)${C_RST}"; fi
    printf '  %-28s %9s %9s   %b\n' "$label" "$e" "$d" "$state"
  done < <(group_dirs "$GROUP")
  printf '  %-28s %9s %9s\n' "TOTAL" "$te" "$td"
}

# --- rename ----------------------------------------------------------------
do_toggle() {
  local want="$1" from to verb
  if [ "$want" = "off" ]; then from=enabled; to=disabled; verb="Disabling"
  else                          from=disabled; to=enabled; verb="Enabling"; fi

  [ "$DRY" -eq 1 ] && info "${C_YEL}*** DRY RUN — no files will be renamed ***${C_RST}"
  info "Movies root: $MOVIES"

  local total=0 done_n=0 skipped=0
  while IFS=$'\t' read -r label sub mode; do
    [ -n "$label" ] || continue
    local n; n=$(count_files "$sub" "$mode" "$from")
    step "$verb: $label   ($n file(s) to rename)"
    if [ "$n" -eq 0 ]; then
      local other; other=$(count_files "$sub" "$mode" "$to")
      if [ "$other" -gt 0 ]; then ok "already $(printf %s "$want" | tr '[:lower:]' '[:upper:]') — $other file(s), nothing to do"
      else                        info "    (no movie files here)"; fi
      continue
    fi
    while IFS= read -r -d '' f; do
      local dst
      if [ "$want" = "off" ]; then dst="$f.disabled"; else dst="${f%.disabled}"; fi
      total=$((total+1))
      if [ -e "$dst" ]; then
        warn "target exists, skipping: $(basename "$dst")"
        skipped=$((skipped+1)); continue
      fi
      if [ "$DRY" -eq 1 ]; then
        printf '    WOULD: %s\n           -> %s\n' "${f#$MOVIES/}" "${dst##*/}"
      else
        if mv -n -- "$f" "$dst"; then done_n=$((done_n+1))
        else fail "rename failed: $f"; fi
      fi
    done < <(list_files "$sub" "$mode" "$from")
    [ "$DRY" -eq 0 ] && ok "renamed $done_n so far"
  done < <(group_dirs "$GROUP")

  info ""
  if [ "$DRY" -eq 1 ]; then
    info "Dry run complete: $total file(s) would be renamed."
    info "Re-run without --dry-run to apply."
  else
    info "Renamed $done_n file(s); $skipped skipped."
    info ""
    do_status
  fi
}

case "$ACTION" in
  status) do_status ;;
  on|off) do_toggle "$ACTION" ;;
esac
