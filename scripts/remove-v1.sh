#!/bin/sh
# remove-v1.sh — remove OpenCode v1 (and side-by-side leftovers) after v2
# has taken over as `opencode`.
#
# Safety gates (all must pass or the script aborts without deleting):
#   1. `opencode --version` reports v2.x  (i.e. install.sh already ran)
#   2. the v2 binary exists and is executable
#
# Removed:
#   $PREFIX/bin/opencode2                 side-by-side v2 wrapper
#   $PREFIX/bin/opencode2-shared          side-by-side shared-mode helper
#   $PREFIX/bin/opencode.v1.bak           v1 wrapper backup made by install.sh
#   $PREFIX/libexec/opencode/opencode-musl.bin    v1 Bun musl binary
#   $PREFIX/libexec/opencode/opencode.bin         pre-musl glibc-era binary
#
# Never touched:
#   opencode-v2-musl.bin, proxy.py, musl loader/libs, libresolvefix.so,
#   ~/.local/share/opencode (session data), ~/.config/opencode (config)
#
# Usage:
#   sh scripts/remove-v1.sh          # prompts before deleting
#   sh scripts/remove-v1.sh --yes    # non-interactive

set -e

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ASSUME_YES=0
[ "$1" = "--yes" ] && ASSUME_YES=1

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

V2_BIN="$PREFIX/libexec/opencode/opencode-v2-musl.bin"

# --- Safety gate 1: `opencode` must already be v2 ---
CUR_VER="$(command -v opencode >/dev/null 2>&1 && opencode --version 2>/dev/null || true)"
case "$CUR_VER" in
  *v2.*) : ;;
  *) die "'opencode --version' did not report v2 (got: ${CUR_VER:-nothing}). Run sh install.sh first." ;;
esac

# --- Safety gate 2: v2 binary must exist ---
[ -x "$V2_BIN" ] || die "v2 binary missing at $V2_BIN — nothing to fall back on, aborting."

log "opencode is v2 ($CUR_VER); v2 binary present at $V2_BIN"

TARGETS=""
for f in \
  "$PREFIX/bin/opencode2" \
  "$PREFIX/bin/opencode2-shared" \
  "$PREFIX/bin/opencode.v1.bak" \
  "$PREFIX/libexec/opencode/opencode-musl.bin" \
  "$PREFIX/libexec/opencode/opencode.bin"
do
  [ -e "$f" ] && TARGETS="$TARGETS $f"
done

if [ -z "$TARGETS" ]; then
  log "Nothing to remove — already clean."
  exit 0
fi

FREED=0
for f in $TARGETS; do
  SIZE=$(stat -c %s "$f" 2>/dev/null || echo 0)
  FREED=$((FREED + SIZE))
done
FREED_MB=$((FREED / 1024 / 1024))

log "Will remove ($FREED_MB MB total):"
for f in $TARGETS; do
  printf '  %s\n' "$f"
done

if pgrep -f "opencode-musl\.bin" >/dev/null 2>&1; then
  log "note: a v1 process is still running; its file will vanish on next start."
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Proceed? [y/N] '
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES) : ;;
    *) log "Aborted."; exit 1 ;;
  esac
fi

for f in $TARGETS; do
  rm -f "$f"
  log "removed $f"
done

log "Done. ~${FREED_MB} MB freed. v2 data/config untouched."
