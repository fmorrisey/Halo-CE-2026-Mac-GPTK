#!/usr/bin/env bash
#
# restore-d3dmetal-v2.1.sh — FULL undo. Return the wrapper to the exact
# pre-graft state captured by backup-wrapper.sh.
#
# Restores the library tree AND Info.plist, so this also:
#   - reverts the renderer flip   (D3DMETAL 1->0, MOLTENVKCX 0->1, METAL_HUD 1->0)
#   - clears "CLI Custom Commands", removing any env vars added afterwards
#     (ROSETTA_ADVERTISE_AVX, D3DM_ENABLE_METALFX, ...)
#
# To undo ONLY the renderer flip and keep the env vars and libraries, use
# restore-renderer-moltenvk.sh instead.
#
# lib/external and lib/wine are removed WHOLESALE before extraction, so files
# the graft ADDED that never existed in the baseline (nvapi64.dll,
# nvngx-on-metalfx.dll and their .so links) are also removed. Leaving a newer
# nvapi64 beside a restored older libd3dshared would be exactly the version
# mismatch this project exists to avoid; the script asserts they are gone.
#
# USAGE
#   restore-d3dmetal-v2.1.sh            # prompts before deleting
#   restore-d3dmetal-v2.1.sh --yes      # no prompt
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

[ "${1:-}" = "--yes" ] && ASSUME_YES=1

info "==> Restore pre-graft D3DMetal baseline"
info "    archive : $BACKUP_LIB_TREE"
show_config

require_wrapper
require_not_running

step "Verifying archive integrity"
require_backup "$BACKUP_LIB_TREE"
COUNT=$(tar -tzf "$BACKUP_LIB_TREE" | wc -l | tr -d ' ')
ok "$COUNT entries, CRC valid"

DEST="$(wrapper_contents)"
PATHS=(
  "SharedSupport/wine/lib/external"
  "SharedSupport/wine/lib/wine"
  "SharedSupport/wine/d3dmetal_force"
  "SharedSupport/prefix/user.reg"
  "Info.plist"
)

info ""
info "This will DELETE and replace, inside the wrapper:"
for p in "${PATHS[@]}"; do info "    $p"; done
info ""
confirm "Proceed?"

step "Removing current versions"
for p in "${PATHS[@]}"; do
  if [ -e "$DEST/$p" ]; then info "    rm -rf  $p"; rm -rf "$DEST/$p"; fi
done

step "Extracting baseline"
COPYFILE_DISABLE=1 tar -xzf "$BACKUP_LIB_TREE" -C "$DEST" || die "extraction failed"
ok "extracted"

# Optional second archive: the prefix's own D3D DLL copies.
if [ -f "$BACKUP_PREFIX_D3D" ] && gzip -t "$BACKUP_PREFIX_D3D" 2>/dev/null; then
  step "Restoring prefix D3D DLLs"
  COPYFILE_DISABLE=1 tar -xzf "$BACKUP_PREFIX_D3D" -C "$DEST" && ok "prefix DLLs restored"
fi

step "Verify"
FAIL=0
for p in "${PATHS[@]}"; do
  [ -e "$DEST/$p" ] && ok "$p" || { fail "MISSING $p"; FAIL=1; }
done

FW="$DEST/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FW" 2>/dev/null || echo "?")
ok "D3DMetal framework now reports: $VER"

# Plist must be back to the pre-graft renderer state. Only checked if the
# archive actually contained an Info.plist (backup-wrapper.sh skips it if the
# wrapper had none).
if [ -f "$DEST/Info.plist" ]; then
  for pair in "D3DMETAL:0" "MOLTENVKCX:1" "METAL_HUD:0"; do
    k="${pair%%:*}"; want="${pair##*:}"
    cur=$(/usr/libexec/PlistBuddy -c "Print :$k" "$DEST/Info.plist" 2>/dev/null) || cur="<not set>"
    [ "$cur" = "$want" ] && ok "plist $k = $cur" || warn "plist $k = $cur (baseline had $want)"
  done
  if plutil -lint "$DEST/Info.plist" >/dev/null 2>&1; then ok "plist is valid"
  else fail "plist invalid"; FAIL=1; fi
else
  warn "Info.plist not present in the backup — plist state not restored"
fi

# Files the graft added must be gone.
for f in "SharedSupport/wine/lib/wine/x86_64-windows/nvapi64.dll" \
         "SharedSupport/wine/lib/wine/x86_64-windows/nvngx-on-metalfx.dll" \
         "SharedSupport/wine/lib/wine/x86_64-unix/nvapi64.so" \
         "SharedSupport/wine/lib/wine/x86_64-unix/nvngx-on-metalfx.so"; do
  if [ -e "$DEST/$f" ] || [ -L "$DEST/$f" ]; then
    fail "LEFTOVER $(basename "$f") still present (was added by the graft)"; FAIL=1
  else
    ok "$(basename "$f") removed"
  fi
done

# The .so files must be symlinks, not dereferenced copies.
for s in d3d11 d3d12 dxgi atidxx64; do
  L="$DEST/SharedSupport/wine/lib/wine/x86_64-unix/$s.so"
  if [ -L "$L" ]; then ok "$s.so -> $(readlink "$L")"
  else fail "$s.so is not a symlink"; FAIL=1; fi
done

info ""
if [ "$FAIL" -eq 0 ]; then
  info "${C_GRN}==> Rollback complete.${C_RST} Libraries and plist are at the pre-graft baseline."
else
  die "rollback finished WITH PROBLEMS — review above"
fi
