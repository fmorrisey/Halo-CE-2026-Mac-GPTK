#!/usr/bin/env bash
#
# overlay-gptk.sh — graft Apple's GPTK D3DMetal libraries into a Wineskin /
# Porting Kit wrapper, replacing the older D3DMetal the wrapper shipped with.
#
# You must supply the GPTK redist yourself (Apple Developer account required).
# Nothing from Apple is redistributed by this repository.
#
# USAGE
#   overlay-gptk.sh --dry-run     # print every copy, change nothing (default)
#   overlay-gptk.sh --execute     # actually copy
#
#   WRAPPER_APP=... GPTK_VOLUME=... overlay-gptk.sh --dry-run
#
# WHAT IT COPIES ("standard" scope — see docs/README.md for the reasoning)
#   lib/external/D3DMetal.framework      replaced   (version-coupled pair:
#   lib/external/libd3dshared.dylib      replaced    both must move together)
#   x86_64-windows/d3d11.dll             replaced
#   x86_64-windows/d3d12.dll             replaced
#   x86_64-windows/dxgi.dll              replaced
#   x86_64-windows/nvapi64.dll           added
#   x86_64-windows/nvngx-on-metalfx.dll  added  (backs D3DM_ENABLE_METALFX)
#   x86_64-unix/{nvapi64,nvngx-on-metalfx}.so -> ../../external/libd3dshared.dylib
#
# WHAT IT DELIBERATELY DOES NOT TOUCH
#   d3d10.dll        The redist ships one, but the wrapper's is base Wine's and
#                    its siblings (d3d10_1, d3d10core) have no redist
#                    counterpart. Overwriting only d3d10 splits that trio. D3D12
#                    titles never load it. Left alone.
#   winemetal.dll    The redist ships NO replacement. It belongs to the base
#                    Wine build. This is the one version seam the graft cannot
#                    close — see "Residual risk" in docs/README.md.
#   d3d12core.dll, d3d9.dll, i386-windows/*   base Wine, never part of GPTK.
#   drive_c prefix DLLs   WINEDLLOVERRIDES forces builtin, so these are bypassed.
#   atidxx64.so      Kept: newer redists drop it, but it still resolves.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

MODE="dry"
for a in "$@"; do
  case "$a" in
    --execute) MODE="exec" ;;
    --dry-run|-n) MODE="dry" ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done

SRC="$(redist_lib)"
EXT="$(lib_external)"
WIN="$(win64_dir)"
UNX="$(unix64_dir)"

if [ "$MODE" = "dry" ]; then
  info "${C_YEL}*** DRY RUN — nothing will be written ***${C_RST}"
else
  info "${C_RED}*** EXECUTING ***${C_RST}"
fi
show_config with-redist

# --------------------------------------------------------------------------
step "Preflight"
require_wrapper
[ -d "$SRC" ] || die "GPTK redist not found at: $SRC
  Mount Apple's 'Evaluation environment for Windows games' dmg and set:
    export GPTK_VOLUME=\"/Volumes/<the volume name>\""

REQUIRED=(
  "external/D3DMetal.framework"
  "external/libd3dshared.dylib"
  "wine/x86_64-windows/d3d11.dll"
  "wine/x86_64-windows/d3d12.dll"
  "wine/x86_64-windows/dxgi.dll"
)
OPTIONAL=(
  "wine/x86_64-windows/nvapi64.dll"
  "wine/x86_64-windows/nvngx-on-metalfx.dll"
)
for f in "${REQUIRED[@]}"; do
  [ -e "$SRC/$f" ] || die "redist is missing a required file: $f
  This may be a different GPTK layout than expected. Stopping rather than guess."
done
ok "redist layout matches expectations"

# Report the version being grafted in, so the run is self-documenting.
FW_PLIST="$SRC/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
SRC_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FW_PLIST" 2>/dev/null || echo "?")
CUR_PLIST="$EXT/D3DMetal.framework/Versions/A/Resources/Info.plist"
CUR_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CUR_PLIST" 2>/dev/null || echo "none")
ok "D3DMetal: wrapper has ${CUR_VER}, redist provides ${SRC_VER}"
case "$SRC_VER" in
  *b*) warn "redist is a BETA ($SRC_VER). Unsupported; keep your backups." ;;
esac

require_not_running
ok "wrapper is not running"

for b in "$BACKUP_LIB_TREE" "$BACKUP_PREFIX_D3D"; do
  if [ -f "$b" ]; then
    gzip -t "$b" && ok "backup verified: $(basename "$b")"
  else
    warn "backup missing: $(basename "$b")"
    warn "run scripts/backup-wrapper.sh first — this overwrites files irreversibly"
    [ "$MODE" = "exec" ] && die "refusing to execute without backups"
  fi
done

# --------------------------------------------------------------------------
run() {
  if [ "$MODE" = "dry" ]; then printf '    WOULD: %s\n' "$*"
  else printf '    %s\n' "$*"; "$@" || die "command failed: $*"; fi
}
sz() { stat -f%z "$1" 2>/dev/null || echo "?"; }

step "1. lib/external — framework + bridge (version-coupled, move together)"
info "    D3DMetal.framework   $CUR_VER -> $SRC_VER"
run rm -rf "$EXT/D3DMetal.framework"
run ditto "$SRC/external/D3DMetal.framework" "$EXT/D3DMetal.framework"
info "    libd3dshared.dylib   $(sz "$EXT/libd3dshared.dylib") -> $(sz "$SRC/external/libd3dshared.dylib")"
run ditto "$SRC/external/libd3dshared.dylib" "$EXT/libd3dshared.dylib"

step "2. x86_64-windows — replace the GPTK PE forwarders"
for d in d3d11 d3d12 dxgi; do
  info "    $d.dll   $(sz "$WIN/$d.dll") -> $(sz "$SRC/wine/x86_64-windows/$d.dll")"
  run ditto "$SRC/wine/x86_64-windows/$d.dll" "$WIN/$d.dll"
done

step "3. x86_64-windows — files the newer redist adds"
ADDED=()
for f in "${OPTIONAL[@]}"; do
  b="$(basename "$f")"
  if [ -e "$SRC/$f" ]; then
    info "    $b   (new, $(sz "$SRC/$f") bytes)"
    run ditto "$SRC/$f" "$WIN/$b"
    ADDED+=("${b%.dll}")
  else
    info "    $b   (not in this redist, skipping)"
  fi
done

step "4. x86_64-unix — symlinks for the added DLLs"
info "    (existing d3d11/d3d12/dxgi/atidxx64 .so links already point correctly)"
for s in ${ADDED[@]+"${ADDED[@]}"}; do
  info "    $s.so -> ../../external/libd3dshared.dylib"
  run ln -sfn "../../external/libd3dshared.dylib" "$UNX/$s.so"
done

step "5. Normalize permissions to match the surrounding tree"
run chmod 644 "$WIN/d3d11.dll" "$WIN/d3d12.dll" "$WIN/dxgi.dll"
for s in ${ADDED[@]+"${ADDED[@]}"}; do run chmod 644 "$WIN/$s.dll"; done
run chmod 755 "$EXT/libd3dshared.dylib"
if [ "$MODE" = "exec" ]; then
  xattr -dr com.apple.quarantine "$EXT" "$WIN" 2>/dev/null || true
fi
info "    (strip com.apple.quarantine from copied files)"

# --------------------------------------------------------------------------
step "NOT touched"
cat <<'K'
    d3d10.dll / d3d10_1.dll / d3d10core.dll   base Wine
    winemetal.dll / d3d12core.dll / d3d9.dll  base Wine
    atidxx64.so, d3d11.so, d3d12.so, dxgi.so  targets already correct
    entire i386-windows tree                  never GPTK
    drive_c prefix DLLs                       builtin override bypasses them
K

if [ "$MODE" = "dry" ]; then
  info ""
  info "Dry run complete. Re-run with --execute to apply."
  exit 0
fi

# --------------------------------------------------------------------------
step "Verify"
FAIL=0
NEW_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CUR_PLIST" 2>/dev/null || echo "?")
[ "$NEW_VER" = "$SRC_VER" ] && ok "framework in place reports $NEW_VER" \
                            || { fail "framework reports $NEW_VER, expected $SRC_VER"; FAIL=1; }

# A failed signature here means the copy corrupted the bundle.
if codesign --verify --deep --strict "$EXT/D3DMetal.framework" 2>/dev/null; then
  ok "code signature valid after copy"
else
  fail "code signature INVALID — the framework copy is damaged"; FAIL=1
fi

for s in d3d11 d3d12 dxgi atidxx64 ${ADDED[@]+"${ADDED[@]}"}; do
  L="$UNX/$s.so"
  if [ -L "$L" ] && [ -e "$L" ]; then ok "$s.so -> $(readlink "$L")"
  elif [ -e "$L" ];                then fail "$s.so exists but is not a symlink"; FAIL=1
  else                                  warn "$s.so absent (fine if this redist omits it)"; fi
done

info ""
if [ "$FAIL" -eq 0 ]; then
  info "${C_GRN}==> Overlay complete.${C_RST} D3DMetal is now $NEW_VER."
  info "    Roll back with: scripts/restore-d3dmetal-v2.1.sh"
else
  die "overlay finished WITH PROBLEMS — review above, consider rolling back"
fi
