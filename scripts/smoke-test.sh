#!/bin/sh
# smoke-test.sh — verify install.sh into a temporary PREFIX.
#
# Usage:
#   ./scripts/smoke-test.sh
#
# Exit status: 0 on success, 1 on any failed check. Network is required.

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-$HOME/tmp}/opencode-smoke.$$"
export PREFIX="$WORK/prefix"
# Keep smoke test from touching the real home config/service
export HOME="$WORK/home"
mkdir -p "$HOME"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }
note() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$WORK" "$PREFIX" "$HOME"
trap 'rm -rf "$WORK"' EXIT

note "Running install.sh into $PREFIX ..."
sh "$REPO_DIR/install.sh" >/dev/null

note "Checking installed files..."
[ -x "$PREFIX/bin/opencode" ]                                || fail "wrapper missing"
[ -x "$PREFIX/libexec/opencode/opencode-v2-musl.bin" ]       || fail "v2 binary missing"
[ -x "$PREFIX/lib/ld-musl-aarch64.so.1" ]                    || fail "musl loader missing"
[ -e "$PREFIX/lib/libresolvefix.so" ]                        || fail "libresolvefix missing"
[ -e "$PREFIX/lib/libstdc++.so.6" ]                          || fail "libstdc++ symlink missing"
[ -x "$PREFIX/bin/opencode-shared" ]                         || fail "opencode-shared helper missing"
pass "files in place"

note "Checking ELF interpreter..."
INTERP=$(readelf -l "$PREFIX/libexec/opencode/opencode-v2-musl.bin" 2>/dev/null \
         | sed -n 's/.*program interpreter: *\(\[[^]]*\]\|\S*\).*/\1/p' \
         | head -1 | tr -d '[]')
[ "$INTERP" = "$PREFIX/lib/ld-musl-aarch64.so.1" ] \
  || fail "interpreter is '$INTERP', expected '$PREFIX/lib/ld-musl-aarch64.so.1'"
pass "interpreter = $INTERP"

note "Running opencode --version ..."
VERSION=$(PATH="$PREFIX/bin:$PATH" TERMUX_VERSION=test PREFIX="$PREFIX" \
          HOME="$WORK/home" sh "$PREFIX/bin/opencode" --version 2>&1)
echo "$VERSION" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' \
  || fail "unexpected --version output: $VERSION"
echo "$VERSION" | grep -qE '^opencode v?2\.' \
  || fail "expected a v2 version string, got: $VERSION"
pass "version = $VERSION"

note "Wrapper-only reinstall path..."
OPENCODE_WRAPPER_ONLY=1 sh "$REPO_DIR/install.sh" >/dev/null
VERSION2=$(PATH="$PREFIX/bin:$PATH" TERMUX_VERSION=test PREFIX="$PREFIX" \
           HOME="$WORK/home" sh "$PREFIX/bin/opencode" --version 2>&1)
echo "$VERSION2" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' \
  || fail "wrapper-only reinstall broke --version: $VERSION2"
pass "wrapper-only reinstall ok"

note "All checks passed."
