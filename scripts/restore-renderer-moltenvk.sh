#!/usr/bin/env bash
#
# restore-renderer-moltenvk.sh — surgical undo of the renderer flip only.
#
# Puts three Info.plist keys back:
#     D3DMETAL    1 -> 0    (D3DMetal off)
#     MOLTENVKCX  0 -> 1    (MoltenVK path back on)
#     METAL_HUD   1 -> 0    (wrapper-scoped Metal HUD off)
#
# Leaves alone: D3DMETAL_FORCE, WINEMSYNC, "CLI Custom Commands", and every
# file under lib/external and lib/wine.
#
# For a full return to the pre-graft state, use restore-d3dmetal-v2.1.sh.
#
# NOTE: on the wrapper this was developed against, MOLTENVKCX turned out to be
# a red herring — the game is D3D12 and was using D3DMetal regardless of this
# setting. See docs/EVIDENCE.md. This script exists to undo the experiment
# cleanly, not because the flip was the fix.
#
# USAGE
#   restore-renderer-moltenvk.sh
#   restore-renderer-moltenvk.sh --yes
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

[ "${1:-}" = "--yes" ] && ASSUME_YES=1

P="$(info_plist)"
RESTORE=( "D3DMETAL:0" "MOLTENVKCX:1" "METAL_HUD:0" )
PRESERVE=( "D3DMETAL_FORCE" "WINEMSYNC" "CLI Custom Commands" )

info "==> Revert renderer to the MoltenVK-path defaults"
info "    plist: $P"
require_wrapper
[ -f "$P" ] || die "Info.plist not found: $P"
require_not_running

step "Current values"
for pair in "${RESTORE[@]}"; do
  k="${pair%%:*}"; want="${pair##*:}"
  cur=$(/usr/libexec/PlistBuddy -c "Print :$k" "$P" 2>/dev/null) || cur="<not set>"
  if [ "$cur" = "$want" ]; then info "    $k = $cur  (already correct)"
  else info "    $k = $cur  ->  $want"; fi
done

info ""
confirm "Apply?"

step "Writing"
for pair in "${RESTORE[@]}"; do
  k="${pair%%:*}"; want="${pair##*:}"
  /usr/libexec/PlistBuddy -c "Set :$k $want" "$P" || die "failed to set $k"
  info "    set $k = $want"
done

step "Verify"
FAIL=0
for pair in "${RESTORE[@]}"; do
  k="${pair%%:*}"; want="${pair##*:}"
  cur=$(/usr/libexec/PlistBuddy -c "Print :$k" "$P" 2>/dev/null) || cur="<not set>"
  [ "$cur" = "$want" ] && ok "$k = $cur" || { fail "$k = $cur (expected $want)"; FAIL=1; }
done
info "    -- preserved (should be unchanged) --"
for k in "${PRESERVE[@]}"; do
  info "    $k = [$(/usr/libexec/PlistBuddy -c "Print :\"$k\"" "$P" 2>/dev/null || echo '<not set>')]"
done
plutil -lint "$P" >/dev/null && ok "plist is valid" || { fail "plist invalid"; FAIL=1; }

FW="$(lib_external)/D3DMetal.framework/Versions/A/Resources/Info.plist"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FW" 2>/dev/null || echo "?")
info "    D3DMetal framework on disk: $VER (unchanged — this script edits only the plist)"

info ""
[ "$FAIL" -eq 0 ] && info "${C_GRN}==> Renderer reverted.${C_RST}" || die "revert FAILED"
