#!/usr/bin/env bash
#
# check-no-binaries.sh — refuse to let Apple binaries into this repo.
#
# Apple's GPTK license does not permit redistributing D3DMetal. This repo
# ships scripts and docs only; users obtain the redist from Apple themselves.
#
# Checks the git INDEX (what is actually about to be committed), not the
# working tree, so an ignored-but-force-added file is still caught.
#
# Usage:
#   scripts/check-no-binaries.sh          # check staged files
#   scripts/check-no-binaries.sh --all    # check every tracked file
#
# Install as a pre-commit hook:
#   git config core.hooksPath .githooks
#
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }

# Extensions/names that may never be committed.
FORBIDDEN_RE='\.(dylib|framework|dll|so|metallib|tar|tar\.gz|tgz|zip|dmg|7z|dmp)$|(^|/)(D3DMetal|libd3dshared)'

# Size ceiling: a stray large file is a red flag even if the name looks fine.
MAX_BYTES=$((2 * 1024 * 1024))

if [ "${1:-}" = "--all" ]; then
  MODE="tracked"; FILES=$(git ls-files)
else
  MODE="staged"; FILES=$(git diff --cached --name-only --diff-filter=ACMR)
fi

if [ -z "$FILES" ]; then
  echo "${GRN}OK${RST}: no $MODE files to check."
  exit 0
fi

FAIL=0

# --- 1. forbidden names ---
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if printf '%s\n' "$f" | grep -qEi "$FORBIDDEN_RE"; then
    echo "${RED}BLOCKED${RST}: $f"
    echo "         matches the Apple-binary / archive denylist."
    FAIL=1
  fi
done <<< "$FILES"

# --- 2. oversized files ---
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$MAX_BYTES" ]; then
    echo "${YEL}WARNING${RST}: $f is $((sz / 1024)) KB (> $((MAX_BYTES / 1024)) KB)"
    echo "         large files are suspicious in a scripts-and-docs repo."
    FAIL=1
  fi
done <<< "$FILES"

# --- 3. Mach-O / archive magic bytes, whatever the file is named ---
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  desc=$(file -b "$f" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')
  case "$desc" in
    *Mach-O*|*"PE32"*|*"gzip compressed"*|*"Zip archive"*|*"current ar archive"*)
      echo "${RED}BLOCKED${RST}: $f"
      echo "         content looks like a binary/archive: $desc"
      FAIL=1
      ;;
  esac
done <<< "$FILES"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "${GRN}OK${RST}: no Apple binaries or archives among $MODE files."
else
  echo "${RED}FAILED${RST}: remove the files above before committing."
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "  git restore --staged <file>"
  else
    echo "  git rm --cached <file>      # no commits yet"
  fi
  echo
  echo "  This repo must never redistribute Apple's D3DMetal binaries."
fi
exit "$FAIL"
