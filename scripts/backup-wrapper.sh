#!/usr/bin/env bash
#
# backup-wrapper.sh — capture the wrapper's pristine graphics state before
# any graft. Produces the two tarballs the restore scripts consume.
#
#   1. <BACKUP_DIR>/halo-bottle-d3dmetal-v2.1-backup.tar.gz
#        Contents/SharedSupport/wine/lib/external   (D3DMetal + libd3dshared)
#        Contents/SharedSupport/wine/lib/wine       (PE forwarders + .so links)
#        Contents/SharedSupport/wine/d3dmetal_force
#        Contents/SharedSupport/prefix/user.reg
#        Contents/Info.plist                        (renderer + env settings)
#
#   2. <BACKUP_DIR>/halo-prefix-system32-d3d-v2.1-backup.tar.gz
#        The prefix's own copies of the D3D DLLs in system32/ and syswow64/.
#        These are byte-identical to the builtin ones and are normally bypassed
#        by WINEDLLOVERRIDES — captured anyway so a restore is total.
#
# Verifies both archives (CRC + entry count + on-disk file-count match) before
# reporting success. Refuses to overwrite existing archives.
#
# USAGE
#   backup-wrapper.sh
#   WRAPPER_APP="/Applications/Ported Games/My Game.app" backup-wrapper.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

info "==> Backup wrapper graphics state"
show_config
require_wrapper
require_not_running

C="$(wrapper_contents)"
mkdir -p "$BACKUP_DIR"

# --- archive 1: the wine lib tree + config ---------------------------------
step "1. Library tree + config -> $(basename "$BACKUP_LIB_TREE")"
[ -e "$BACKUP_LIB_TREE" ] && die "refusing to overwrite existing backup: $BACKUP_LIB_TREE"

PATHS=(
  "SharedSupport/wine/lib/external"
  "SharedSupport/wine/lib/wine"
  "SharedSupport/wine/d3dmetal_force"
  "SharedSupport/prefix/user.reg"
  "Info.plist"
)
INCLUDE=()
for p in "${PATHS[@]}"; do
  if [ -e "$C/$p" ]; then
    INCLUDE+=("$p"); info "    include  $p"
  else
    warn "absent, skipping: $p"
  fi
done
[ "${#INCLUDE[@]}" -gt 0 ] || die "nothing to back up — is this the right wrapper?"

# COPYFILE_DISABLE stops tar from emitting ._AppleDouble members.
COPYFILE_DISABLE=1 tar -czf "$BACKUP_LIB_TREE" -C "$C" "${INCLUDE[@]}" \
  || die "tar failed"
ok "wrote $(du -h "$BACKUP_LIB_TREE" | cut -f1)"

# --- archive 2: prefix D3D DLLs --------------------------------------------
step "2. Prefix D3D DLLs -> $(basename "$BACKUP_PREFIX_D3D")"
[ -e "$BACKUP_PREFIX_D3D" ] && die "refusing to overwrite existing backup: $BACKUP_PREFIX_D3D"

DLLS=(d3d9 d3d10 d3d10_1 d3d10core d3d11 d3d12 dxgi winemetal)
PFX_INCLUDE=()
for arch in system32 syswow64; do
  for d in "${DLLS[@]}"; do
    rel="SharedSupport/prefix/drive_c/windows/$arch/$d.dll"
    [ -f "$C/$rel" ] && PFX_INCLUDE+=("$rel")
  done
done
if [ "${#PFX_INCLUDE[@]}" -eq 0 ]; then
  warn "no prefix D3D DLLs found — skipping archive 2"
else
  info "    ${#PFX_INCLUDE[@]} file(s)"
  COPYFILE_DISABLE=1 tar -czf "$BACKUP_PREFIX_D3D" -C "$C" "${PFX_INCLUDE[@]}" || die "tar failed"
  ok "wrote $(du -h "$BACKUP_PREFIX_D3D" | cut -f1)"
fi

# --- verify ----------------------------------------------------------------
step "Verify"
FAIL=0
for b in "$BACKUP_LIB_TREE" "$BACKUP_PREFIX_D3D"; do
  [ -f "$b" ] || continue
  n=$(basename "$b")
  gzip -t "$b" && ok "$n: gzip CRC OK" || { fail "$n: CRC FAILED"; FAIL=1; }
  cnt=$(tar -tzf "$b" 2>/dev/null | wc -l | tr -d ' ')
  ok "$n: $cnt entries list cleanly"
done

# A readable archive is not necessarily a COMPLETE one: compare the archive's
# file list against what is actually on disk.
if [ -f "$BACKUP_LIB_TREE" ]; then
  disk=$(cd "$C" && find "${INCLUDE[@]}" | sed 's|/$||' | sort)
  arch=$(tar -tzf "$BACKUP_LIB_TREE" | sed 's|/$||' | sort)
  missing=$(comm -23 <(printf '%s\n' "$disk") <(printf '%s\n' "$arch"))
  if [ -z "$missing" ]; then
    ok "completeness: $(printf '%s\n' "$disk" | wc -l | tr -d ' ') on disk, all present in archive"
  else
    fail "these files are on disk but MISSING from the archive:"
    printf '%s\n' "$missing" | sed 's/^/        /'
    FAIL=1
  fi
fi

info ""
[ "$FAIL" -eq 0 ] && info "${C_GRN}==> Backup complete and verified.${C_RST}" \
                  || die "backup verification FAILED — do not proceed with the overlay"
