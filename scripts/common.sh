#!/usr/bin/env bash
#
# common.sh — shared configuration and helpers.
# Sourced by every script here; not meant to be run directly.
#
# ---------------------------------------------------------------------------
# CONFIGURATION
#
# Everything machine-specific is a variable. Override by exporting before
# running, or with the flags each script accepts.
#
#   WRAPPER_APP    Path to the Porting Kit / Wineskin .app to modify.
#   GPTK_VOLUME    Path to the mounted GPTK redist volume.
#   BACKUP_DIR     Where backup tarballs are written/read.
#
# Worked example from the machine this was developed on:
#
#   export WRAPPER_APP="/Applications/Ported Games/Halo CE 2026.app"
#   export GPTK_VOLUME="/Volumes/Evaluation environment for Windows games 4.0 beta 2"
#   export BACKUP_DIR="$HOME/Desktop"
#
# ---------------------------------------------------------------------------
set -uo pipefail

WRAPPER_APP="${WRAPPER_APP:-/Applications/Ported Games/<Wrapper>.app}"
GPTK_VOLUME="${GPTK_VOLUME:-/Volumes/Evaluation environment for Windows games 4.0 beta 2}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/Desktop}"

# --- derived paths (do not edit) -------------------------------------------
wrapper_contents() { printf '%s/Contents' "$WRAPPER_APP"; }
wine_root()        { printf '%s/Contents/SharedSupport/wine' "$WRAPPER_APP"; }
lib_external()     { printf '%s/lib/external' "$(wine_root)"; }
lib_wine()         { printf '%s/lib/wine' "$(wine_root)"; }
win64_dir()        { printf '%s/x86_64-windows' "$(lib_wine)"; }
unix64_dir()       { printf '%s/x86_64-unix' "$(lib_wine)"; }
prefix_root()      { printf '%s/Contents/SharedSupport/prefix' "$WRAPPER_APP"; }
info_plist()       { printf '%s/Contents/Info.plist' "$WRAPPER_APP"; }
redist_lib()       { printf '%s/redist/lib' "$GPTK_VOLUME"; }

BACKUP_LIB_TREE="${BACKUP_LIB_TREE:-$BACKUP_DIR/halo-bottle-d3dmetal-v2.1-backup.tar.gz}"
BACKUP_PREFIX_D3D="${BACKUP_PREFIX_D3D:-$BACKUP_DIR/halo-prefix-system32-d3d-v2.1-backup.tar.gz}"

# --- output helpers --------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

info()  { printf '%s\n' "$*"; }
ok()    { printf '    %sOK%s       %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '    %sWARN%s     %s\n' "$C_YEL" "$C_RST" "$*"; }
fail()  { printf '    %sFAILED%s   %s\n' "$C_RED" "$C_RST" "$*"; }
step()  { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
die()   { printf '%sERROR%s: %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# --- guards ----------------------------------------------------------------

# The wrapper must exist and look like a Wineskin/Porting Kit bundle.
require_wrapper() {
  [ -d "$WRAPPER_APP" ] || die "wrapper not found: $WRAPPER_APP
  Set WRAPPER_APP to your .app, e.g.
    export WRAPPER_APP=\"/Applications/Ported Games/My Game.app\""
  [ -d "$(wine_root)" ] || die "not a Wineskin-style wrapper (no Contents/SharedSupport/wine): $WRAPPER_APP"
}

# Never modify a wrapper that is running: DLLs may be mapped by a live
# wineserver, and swapping them underneath it corrupts the session.
require_not_running() {
  local name; name="$(basename "$WRAPPER_APP" .app)"
  if pgrep -f "$name" >/dev/null 2>&1; then
    printf '%sERROR%s: "%s" is RUNNING. Quit the game first.\n' "$C_RED" "$C_RST" "$name" >&2
    pgrep -fl "$name" | sed 's/^/    /' >&2
    exit 1
  fi
}

require_backup() {
  local b="$1"
  [ -f "$b" ] || die "backup not found: $b
  Run scripts/backup-wrapper.sh first."
  gzip -t "$b" || die "backup failed its CRC check: $b"
}

confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local ans
  read -r -p "${1:-Proceed?} [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) info "Aborted."; exit 1 ;; esac
}

# Print the resolved configuration so every run is self-documenting.
show_config() {
  info "    wrapper : $WRAPPER_APP"
  [ "${1:-}" = "with-redist" ] && info "    redist  : $GPTK_VOLUME"
  info "    backups : $BACKUP_DIR"
}
