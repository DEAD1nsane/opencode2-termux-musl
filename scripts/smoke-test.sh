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

note "Running opencode run --help (offline smoke gate)..."
PATH="$PREFIX/bin:$PATH" TERMUX_VERSION=test PREFIX="$PREFIX" \
  HOME="$WORK/home" sh "$PREFIX/bin/opencode" run --help >/dev/null 2>&1 \
  || fail "opencode run --help failed"
pass "run --help exits 0"

note "Checking rollback boundary artifacts..."
[ -f "$PREFIX/libexec/opencode/VERSION" ]      || fail "VERSION sidecar missing"
[ -f "$PREFIX/libexec/opencode/SHA256" ]       || fail "SHA256 sidecar missing"
grep -qE '^[0-9a-f]{64}  ' "$PREFIX/libexec/opencode/SHA256" \
  || fail "SHA256 sidecar malformed: $(cat "$PREFIX/libexec/opencode/SHA256")"
[ -f "$PREFIX/libexec/opencode/versions.log" ] || fail "versions.log missing"
[ ! -e "$PREFIX/libexec/opencode/opencode-v2-musl.bin.new" ] \
  || fail "stale .new staging file left behind"
VER_FILE="$(cat "$PREFIX/libexec/opencode/VERSION")"
echo "$VERSION" | grep -qF "$VER_FILE" \
  || fail "VERSION sidecar ($VER_FILE) disagrees with --version ($VERSION)"
pass "version $VER_FILE pinned with SHA256"

note "Rollback drill: corrupt live binary, restore last-good..."
cp -p "$PREFIX/libexec/opencode/opencode-v2-musl.bin" \
      "$PREFIX/libexec/opencode/opencode-v2-musl.bin.last-good"
printf 'corrupt' > "$PREFIX/libexec/opencode/opencode-v2-musl.bin"
cp -p "$PREFIX/libexec/opencode/opencode-v2-musl.bin.last-good" \
      "$PREFIX/libexec/opencode/opencode-v2-musl.bin"
chmod 755 "$PREFIX/libexec/opencode/opencode-v2-musl.bin"
VERSION3=$(PATH="$PREFIX/bin:$PATH" TERMUX_VERSION=test PREFIX="$PREFIX" \
           HOME="$WORK/home" sh "$PREFIX/bin/opencode" --version 2>&1) \
  || fail "restored binary fails --version"
echo "$VERSION3" | grep -qF "$VER_FILE" \
  || fail "restored binary reports '$VERSION3', expected $VER_FILE"
pass "last-good restore works"

note "Wrapper-only reinstall path..."
OPENCODE_WRAPPER_ONLY=1 sh "$REPO_DIR/install.sh" >/dev/null
VERSION2=$(PATH="$PREFIX/bin:$PATH" TERMUX_VERSION=test PREFIX="$PREFIX" \
           HOME="$WORK/home" sh "$PREFIX/bin/opencode" --version 2>&1)
echo "$VERSION2" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' \
  || fail "wrapper-only reinstall broke --version: $VERSION2"
pass "wrapper-only reinstall ok"

note "All checks passed."
