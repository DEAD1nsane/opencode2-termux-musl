#!/bin/sh
# install.sh — install official OpenCode v2 (Node.js musl build) on Termux.
#
# OpenCode v2 ships via npm (@opencode/cli), not GitHub releases. The official
# curl installer misdetects Termux as glibc (no /etc/alpine-release, no ldd)
# and would download the wrong binary. This script always takes
# @opencode/cli-linux-arm64-musl, patches the ELF interpreter, and installs
# it as `opencode` — the standard upstream command name.
#
# Usage:
#   sh install.sh
#   OPENCODE_WRAPPER_ONLY=1 sh install.sh   # refresh wrapper only, no download
#
# Pin a version:
#   OPENCODE_VERSION=2.0.21 sh install.sh
#
# Offline tarball:
#   OPENCODE_TARBALL_PATH=./cli-linux-arm64-musl-2.0.21.tgz sh install.sh
#
# Environment:
#   OPENCODE_VERSION        pin version (default: latest from opencode.ai)
#   OPENCODE_TARBALL_PATH   use a pre-downloaded npm tarball
#   OPENCODE_EXPECTED_SHA256 require the tarball's SHA256 to match (auto-update
#                           pins the resolved version; set this to pin the hash too)
#   OPENCODE_WRAPPER_ONLY   1 = skip binary download/patch, reinstall wrapper only
#   OPENCODE_RUN_SMOKE      1 = after the offline gates, also run a networked
#                           `opencode run "Reply with exactly: PONG"` gate
#                           (default 0 — needs auth + network, so an offline
#                           phone must not look like a broken binary)
#   OPENCODE_STANDALONE     1 (default) or 0 — inject --standalone for run/serve
#                           (legacy name OPENCODE_V2_STANDALONE is also honored)
#   INSTALL_NAME            wrapper name (default: opencode)
#
# Rollback boundary: the new binary is staged to opencode-v2-musl.bin.new,
# smoke-tested there, and only then promoted over the current binary. The
# previous binary is kept as opencode-v2-musl.bin.last-good with its
# VERSION/SHA256 sidecars, so a bad upstream build restores with:
#   cp "$PREFIX/libexec/opencode/opencode-v2-musl.bin.last-good" \
#      "$PREFIX/libexec/opencode/opencode-v2-musl.bin"
# Promotion gates (offline, deterministic): `opencode --version` matches the
# expected version AND `opencode run --help` exits 0. The networked `run`
# gate is opt-in (OPENCODE_RUN_SMOKE=1) for exactly the reason above.
#
# Requires: curl, tar. Reuses musl loader/libs + libresolvefix when present;
# otherwise installs them from Alpine. Outbound HTTPS goes through the Python
# proxy on 127.0.0.1:8080 — Node/c-ares cannot use musl DNS on Android.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TMPDIR="${TMPDIR:-$HOME/tmp}"
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
OPENCODE_WRAPPER_ONLY="${OPENCODE_WRAPPER_ONLY:-0}"
OPENCODE_STANDALONE="${OPENCODE_STANDALONE:-1}"
# Legacy side-by-side era variable, honored for existing setups.
if [ "$OPENCODE_V2_STANDALONE" = "0" ] || [ "$OPENCODE_V2_STANDALONE" = "false" ]; then
  OPENCODE_STANDALONE=0
fi
if [ "$OPENCODE_V2_STANDALONE" = "1" ] || [ "$OPENCODE_V2_STANDALONE" = "true" ]; then
  OPENCODE_STANDALONE=1
fi
INSTALL_NAME="${INSTALL_NAME:-opencode}"
NPM_SCOPE="${NPM_SCOPE:-@opencode}"
UPDATE_API="${UPDATE_API:-https://opencode.ai/update/api/latest/cli/npm}"

WORK="$TMPDIR/opencode-install.$$"
mkdir -p "$WORK" "$TMPDIR"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] || die "Only aarch64 is supported (got: $ARCH)."

MUSL_LOADER="$PREFIX/lib/ld-musl-aarch64.so.1"
RESOLVEFIX="$PREFIX/lib/libresolvefix.so"
V2_DIR="$PREFIX/libexec/opencode"
V2_BIN="$V2_DIR/opencode-v2-musl.bin"
# Rollback boundary artifacts (alongside the binary, never in PATH).
V2_NEW="$V2_BIN.new"
V2_LASTGOOD="$V2_BIN.last-good"
VERSION_FILE="$V2_DIR/VERSION"
SHA_FILE="$V2_DIR/SHA256"
VERSION_LOG="$V2_DIR/versions.log"
OPENCODE_RUN_SMOKE="${OPENCODE_RUN_SMOKE:-0}"

# SHA256 of a file (sha256sum, or shasum fallback). Prints bare hex.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# run_with_timeout SECS CMD... — timeout when available, plain exec otherwise
# (timeout(1) exists on Termux coreutils; smoke gates must never hang the
# unattended 6h job if a bad binary blocks on startup).
run_with_timeout() {
  _secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_secs" "$@"
  else
    "$@"
  fi
  unset _secs
}

# restore_last_good — copy .last-good back over the current binary.
# Returns 0 on a verified restore, 1 when there is nothing to restore.
restore_last_good() {
  [ -f "$V2_LASTGOOD" ] || return 1
  cp -p "$V2_LASTGOOD" "$V2_BIN"
  chmod 755 "$V2_BIN"
  if [ -f "$VERSION_FILE.last-good" ]; then cp -p "$VERSION_FILE.last-good" "$VERSION_FILE"; fi
  if [ -f "$SHA_FILE.last-good" ]; then cp -p "$SHA_FILE.last-good" "$SHA_FILE"; fi
  return 0
}

# --- Ensure musl loader + C++ libs (from Alpine) ---
ensure_musl_libs() {
  [ -x "$MUSL_LOADER" ] && [ -e "$PREFIX/lib/libstdc++.so.6" ] && [ -e "$PREFIX/lib/libgcc_s.so.1" ] && return 0
  log "Musl libs missing — installing Alpine musl + libstdc++/libgcc..."
  ALPINE_VERSION=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/" \
    | grep -oE 'v[0-9]+\.[0-9]+/' | sort -uV | tail -1 | tr -d /)
  [ -n "$ALPINE_VERSION" ] || die "Could not determine latest Alpine version."
  ALPINE_BASE="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_VERSION/main/aarch64"
  ALPINE_INDEX=$(curl -fsSL "$ALPINE_BASE/" \
    | grep -oE '(musl|libstdc\+\+|libgcc)-[0-9][^"<]*\.apk' | sort -uV)
  MUSL_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^musl-' | tail -1)
  LIBSTDC_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libstdc\+\+-' | tail -1)
  LIBGCC_PKG=$(printf '%s\n' "$ALPINE_INDEX" | grep -E '^libgcc-' | tail -1)
  [ -n "$MUSL_PKG" ] && [ -n "$LIBSTDC_PKG" ] && [ -n "$LIBGCC_PKG" ] \
    || die "Could not find Alpine musl packages."
  cd "$WORK"
  curl -fL --progress-bar -o "$MUSL_PKG" "$ALPINE_BASE/$MUSL_PKG" || die "musl download failed"
  curl -fL --progress-bar -o "$LIBSTDC_PKG" "$ALPINE_BASE/$LIBSTDC_PKG" || die "libstdc++ download failed"
  curl -fL --progress-bar -o "$LIBGCC_PKG" "$ALPINE_BASE/$LIBGCC_PKG" || die "libgcc download failed"
  mkdir -p musl-libs
  for pkg in "$MUSL_PKG" "$LIBSTDC_PKG" "$LIBGCC_PKG"; do
    (cd musl-libs && tar -xzf "../$pkg") || die "Failed to extract $pkg"
  done
  LIBSTDC_FILE=$(ls musl-libs/usr/lib/libstdc++.so.6.*.* 2>/dev/null | head -1)
  [ -n "$LIBSTDC_FILE" ] || die "Could not find libstdc++.so.6.* in extracted package."
  install -d "$PREFIX/lib"
  install -m 755 musl-libs/lib/ld-musl-aarch64.so.1 "$PREFIX/lib/"
  install -m 755 musl-libs/usr/lib/libgcc_s.so.1 "$PREFIX/lib/"
  install -m 755 "$LIBSTDC_FILE" "$PREFIX/lib/"
  rm -f "$PREFIX/lib/libstdc++.so.6"
  ln -s "$(basename "$LIBSTDC_FILE")" "$PREFIX/lib/libstdc++.so.6"
}

ensure_resolvefix() {
  [ -f "$RESOLVEFIX" ] && return 0
  log "Building libresolvefix.so..."
  if ! command -v clang >/dev/null 2>&1; then
    warn "clang not found; attempting Termux install..."
    pkg install -y clang || die "Please install clang: pkg install clang"
  fi
  SRC="$WORK/libresolvefix.c"
  if [ -f "$SCRIPT_DIR/scripts/libresolvefix.c" ]; then
    cp "$SCRIPT_DIR/scripts/libresolvefix.c" "$SRC"
  elif [ -f "$SCRIPT_DIR/libresolvefix.c" ]; then
    cp "$SCRIPT_DIR/libresolvefix.c" "$SRC"
  else
    curl -fsSL -o "$SRC" \
      "https://raw.githubusercontent.com/DEAD1nsane/opencode2-termux-musl/master/scripts/libresolvefix.c" \
      || die "Could not download libresolvefix.c"
  fi
  clang -shared -fPIC -o "$WORK/libresolvefix.so" "$SRC" \
    -Wl,--dynamic-linker="$MUSL_LOADER" \
    -L"$PREFIX/lib" -nostdlib \
    || die "Failed to compile libresolvefix.so"
  install -m 755 "$WORK/libresolvefix.so" "$PREFIX/lib/"
}

ensure_patchelf() {
  command -v patchelf >/dev/null 2>&1 && return 0
  warn "patchelf not found; attempting Termux install..."
  pkg install -y patchelf || die "Please install patchelf: pkg install patchelf"
}

ensure_musl_libs
ensure_resolvefix
ensure_patchelf

# --- Resolve version from official update API (v2 is npm-only) ---
if [ "$OPENCODE_VERSION" = "latest" ]; then
  log "Resolving latest OpenCode v2 version..."
  META=$(curl -fsSL "$UPDATE_API" || true)
  OPENCODE_VERSION=$(printf '%s' "$META" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  # Fall back to the npm registry when the opencode.ai endpoint is down —
  # /latest has the same JSON shape ({"version":"x.y.z",...}).
  if [ -z "$OPENCODE_VERSION" ]; then
    log "Primary update API unreachable, trying npm registry..."
    META=$(curl -fsSL "https://registry.npmjs.org/@opencode%2Fcli/latest" || true)
    OPENCODE_VERSION=$(printf '%s' "$META" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  fi
  [ -n "$OPENCODE_VERSION" ] || die "Could not resolve v2 version from $UPDATE_API"
fi
OPENCODE_VERSION="${OPENCODE_VERSION#v}"

if [ "$OPENCODE_WRAPPER_ONLY" = "1" ]; then
  [ -x "$V2_BIN" ] || die "OPENCODE_WRAPPER_ONLY=1 but $V2_BIN is missing."
  log "Wrapper-only mode: keeping existing binary ($("$V2_BIN" --version 2>/dev/null || echo unknown))"
  if [ "$OPENCODE_VERSION" = "latest" ]; then
    # Gates below compare against a concrete version; read it from the
    # binary we are keeping (or the VERSION sidecar as fallback).
    OPENCODE_VERSION="$("$V2_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -z "$OPENCODE_VERSION" ] && [ -f "$VERSION_FILE" ] && OPENCODE_VERSION="$(cat "$VERSION_FILE")"
    [ -n "$OPENCODE_VERSION" ] || die "Could not read kept binary's version for verification."
  fi
else
  # --- Download official v2 musl npm package ---
  PKG_NAME="cli-linux-arm64-musl"
  TARBALL="${PKG_NAME}-${OPENCODE_VERSION}.tgz"
  URL="https://registry.npmjs.org/${NPM_SCOPE}/${PKG_NAME}/-/${TARBALL}"
  log "Installing OpenCode v2 $OPENCODE_VERSION..."
  log "Downloading $NPM_SCOPE/$PKG_NAME@$OPENCODE_VERSION..."
  if [ -n "$OPENCODE_TARBALL_PATH" ]; then
    [ -f "$OPENCODE_TARBALL_PATH" ] || die "OPENCODE_TARBALL_PATH=$OPENCODE_TARBALL_PATH not found."
    log "Using local tarball: $OPENCODE_TARBALL_PATH"
    cp "$OPENCODE_TARBALL_PATH" "$WORK/$TARBALL"
  else
    # Progress meter only on a real terminal: under the unattended job
    # stderr lands in auto-update's log, where every \r frame appends.
    if [ -t 2 ]; then PROGRESS="--progress-bar"; else PROGRESS="--no-progress-meter"; fi
    # Retry + resume: an 84MB tarball on mobile networks commonly dies
    # mid-transfer (curl 56 SSL EOF); without this the unattended job
    # fails silently and never converges on the new version.
    if ! curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - \
        $PROGRESS -o "$WORK/$TARBALL" "$URL"; then
      log "Hint: download manually, then re-run with OPENCODE_TARBALL_PATH:"
      log "  curl -L -C - -o $TARBALL $URL"
      die "Download failed: $URL"
    fi
  fi

  cd "$WORK"
  # Pin the hash: record the tarball's SHA256, enforce it when pinned.
  TARBALL_SHA256="$(sha256_of "$TARBALL")"
  [ -n "$TARBALL_SHA256" ] || die "Could not hash downloaded tarball"
  log "Tarball SHA256: $TARBALL_SHA256"
  if [ -n "${OPENCODE_EXPECTED_SHA256:-}" ]; then
    _want=$(printf '%s' "$OPENCODE_EXPECTED_SHA256" | tr 'A-F' 'a-f')
    _got=$(printf '%s' "$TARBALL_SHA256" | tr 'A-F' 'a-f')
    [ "$_got" = "$_want" ] || die "SHA256 mismatch: got $_got, expected $_want"
    unset _want _got
    log "SHA256 matches pinned value."
  fi
  tar -xzf "$TARBALL" || die "Failed to extract npm tarball"
  V2_SRC="package/bin/opencode"
  [ -f "$V2_SRC" ] || die "Tarball did not contain package/bin/opencode"

  # --- Stage new binary, smoke-test it, then promote ---
  # The live $V2_BIN is untouched until the staged copy proves itself.
  log "Staging v2 binary..."
  install -d "$PREFIX/libexec/opencode"
  rm -f "$V2_NEW"
  install -m 755 "$V2_SRC" "$V2_NEW"
  log "Patching ELF interpreter to $MUSL_LOADER..."
  patchelf --set-interpreter "$MUSL_LOADER" "$V2_NEW"
  log "Smoke-testing staged binary (gate 1: --version)..."
  STAGED_VERSION="$(LD_PRELOAD="$RESOLVEFIX" LD_LIBRARY_PATH="$PREFIX/lib" \
    run_with_timeout 60 "$V2_NEW" --version 2>&1)" \
    || { rm -f "$V2_NEW"; die "Staged binary failed to run; live binary untouched."; }
  echo "$STAGED_VERSION" | grep -qF "$OPENCODE_VERSION" \
    || { rm -f "$V2_NEW"; die "Staged binary reports '$STAGED_VERSION', expected $OPENCODE_VERSION; live binary untouched."; }
  log "Staged binary reports: $STAGED_VERSION"
  # Promote: snapshot the live binary as last-known-good first.
  if [ -f "$V2_BIN" ]; then
    log "Snapshotting live binary as last-known-good..."
    cp -p "$V2_BIN" "$V2_LASTGOOD"
    chmod 755 "$V2_LASTGOOD"
    [ -f "$VERSION_FILE" ] && cp -p "$VERSION_FILE" "$VERSION_FILE.last-good"
    [ -f "$SHA_FILE" ] && cp -p "$SHA_FILE" "$SHA_FILE.last-good"
  fi
  mv -f "$V2_NEW" "$V2_BIN"
  chmod 755 "$V2_BIN"
  printf '%s\n' "$OPENCODE_VERSION" > "$VERSION_FILE"
  printf '%s  %s-%s.tgz\n' "$TARBALL_SHA256" "$PKG_NAME" "$OPENCODE_VERSION" > "$SHA_FILE"
  printf '%s %s %s\n' "$(date '+%F %T')" "$OPENCODE_VERSION" "$TARBALL_SHA256" >> "$VERSION_LOG"
  log "Promoted v2 $OPENCODE_VERSION to $V2_BIN"
fi

# Proxy watchdog: cron/runit are unavailable on Termux, so the wrapper keeps
# this flock-single-instance daemon alive; it restarts proxy.py within a
# minute if it dies. Remote MCP servers (e.g. railway) fail with "Unable to
# connect" whenever the proxy is down at connect time. Installed outside the
# binary-download guard so OPENCODE_WRAPPER_ONLY=1 refreshes deploy it too.
if [ -f "$SCRIPT_DIR/scripts/proxy-watchdog.sh" ]; then
  install -m 700 "$SCRIPT_DIR/scripts/proxy-watchdog.sh" "$PREFIX/libexec/opencode/proxy-watchdog.sh"
elif [ -f "$SCRIPT_DIR/proxy-watchdog.sh" ]; then
  install -m 700 "$SCRIPT_DIR/proxy-watchdog.sh" "$PREFIX/libexec/opencode/proxy-watchdog.sh"
fi

# --- Wrapper ---
# v2 is Node.js-based. Outbound HTTPS still goes through the Python proxy on
# 127.0.0.1:8080 because Node/c-ares bypasses libresolvefix (raw UDP DNS is
# blocked on Android); the wrapper starts the proxy if it is not running.
# --standalone is a per-command flag (run/serve/web/acp), not global; plain
# TUI launches attach to the shared service when one is running.
log "Installing wrapper $PREFIX/bin/$INSTALL_NAME..."
install -d "$PREFIX/bin"
# npm may leave a dangling symlink at the target name.
if [ -L "$PREFIX/bin/$INSTALL_NAME" ]; then
  log "Removing stale npm symlink $PREFIX/bin/$INSTALL_NAME"
  rm -f "$PREFIX/bin/$INSTALL_NAME"
fi
# Preserve a v1 wrapper before overwriting it (removed later by scripts/remove-v1.sh).
if [ -f "$PREFIX/bin/$INSTALL_NAME" ] && grep -q "opencode-musl\.bin" "$PREFIX/bin/$INSTALL_NAME" 2>/dev/null; then
  log "Backing up v1 wrapper to $PREFIX/bin/$INSTALL_NAME.v1.bak"
  cp "$PREFIX/bin/$INSTALL_NAME" "$PREFIX/bin/$INSTALL_NAME.v1.bak"
fi

case "$OPENCODE_STANDALONE" in
  1|true|yes) STANDALONE=1 ;;
  *) STANDALONE=0 ;;
esac

# Quoted heredoc + sed: avoids dash heredoc expansion pitfalls on Termux.
WRAPPER_TMP="$WORK/opencode.wrapper"
cat > "$WRAPPER_TMP" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/sh
# opencode wrapper — official OpenCode v2 (Node.js musl build) on Termux.
#
# Why this wrapper exists:
#   - upstream is a musl-linked binary; Android's bionic resolver + blocked
#     raw UDP DNS mean musl's default name resolution does not work here,
#     so LD_PRELOAD=libresolvefix.so redirects resolv.conf reads to Termux;
#   - Node/c-ares bypasses even that, so outbound HTTPS is routed through
#     the Python proxy on 127.0.0.1:8080 (started below if missing);
#   - the phone's timezone, CA bundle and TMPDIRs are set explicitly.
#
# Do NOT use env -i: bionic resolver needs the surrounding Android env.
unset LD_PRELOAD
export LD_PRELOAD="@PREFIX@/lib/libresolvefix.so"
export HOME
export PATH
export PREFIX="@PREFIX@"
export TERM="${TERM:-xterm-256color}"
export LANG="${LANG:-en_US.UTF-8}"
if [ -z "$TZ" ]; then
  if command -v getprop >/dev/null 2>&1; then
    __TZ=$(getprop persist.sys.timezone 2>/dev/null)
  else
    __TZ=""
  fi
  if [ -z "$__TZ" ] && [ -e /etc/localtime ]; then
    __TZ=$(readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
  fi
  [ -n "$__TZ" ] && export TZ="$__TZ"
  unset __TZ
fi
export TMPDIR="${TMPDIR:-$HOME/tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
export TERMUX_VERSION
export ANDROID_ROOT="${ANDROID_ROOT:-/system}"
export LD_LIBRARY_PATH="@PREFIX@/lib"
export SSL_CERT_FILE="@PREFIX@/etc/tls/cert.pem"
export NODE_EXTRA_CA_CERTS="@PREFIX@/etc/tls/cert.pem"
export CURL_CA_BUNDLE="@PREFIX@/etc/tls/cert.pem"
export HTTP_PROXY="http://127.0.0.1:8080"
export http_proxy="http://127.0.0.1:8080"
export HTTPS_PROXY="http://127.0.0.1:8080"
export https_proxy="http://127.0.0.1:8080"
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="localhost,127.0.0.1,::1"
export NODE_OPTIONS="--dns-result-order=ipv4first"
# Start the Python proxy if it isn't listening — v2 needs it for opencode.ai / MCP / models.dev.
# Port check, not pgrep: `pgrep -f "proxy.py"` false-matches any cmdline that merely
# mentions the string, so a dead proxy could look alive and remote MCP servers
# (railway) would cache "Unable to connect" per directory.
# PROXY_DEBUG=1 makes proxy.py log crashes to $TMPDIR/proxy.log instead of /dev/null.
if [ -f "@PREFIX@/libexec/opencode/proxy.py" ]; then
  if ! python3 -c 'import socket; s = socket.socket(); s.settimeout(1); s.connect(("127.0.0.1", 8080)); s.close()' 2>/dev/null; then
    PROXY_DEBUG=1 nohup python3 "@PREFIX@/libexec/opencode/proxy.py" >/dev/null 2>&1 &
    sleep 0.3
  fi
  # Keep the proxy watchdog alive. flock inside makes it single-instance,
  # so launching it on every wrapper invocation is safe.
  if [ -x "@PREFIX@/libexec/opencode/proxy-watchdog.sh" ]; then
    nohup "@PREFIX@/libexec/opencode/proxy-watchdog.sh" >/dev/null 2>&1 &
  fi
fi
STANDALONE=@STANDALONE@
if [ "$OPENCODE_STANDALONE" = "1" ] || [ "$OPENCODE_STANDALONE" = "true" ]; then
  STANDALONE=1
fi
if [ "$OPENCODE_STANDALONE" = "0" ] || [ "$OPENCODE_STANDALONE" = "false" ]; then
  STANDALONE=0
fi
# Legacy side-by-side era variable.
if [ "$OPENCODE_V2_STANDALONE" = "1" ] || [ "$OPENCODE_V2_STANDALONE" = "true" ]; then
  STANDALONE=1
fi
if [ "$OPENCODE_V2_STANDALONE" = "0" ] || [ "$OPENCODE_V2_STANDALONE" = "false" ]; then
  STANDALONE=0
fi
if [ "$STANDALONE" = "1" ]; then
  # --standalone is a per-command flag (run/serve/web/acp), not global.
  # Inject it only for run/serve style invocations; otherwise leave args alone.
  case "$1" in
    run|serve|web|acp)
      __sub="$1"
      shift
      set -- "$__sub" --standalone "$@"
      unset __sub
      ;;
  esac
fi
exec "@V2_BIN@" "$@"
WRAPPER
sed -e "s|@PREFIX@|$PREFIX|g" \
    -e "s|@V2_BIN@|$V2_BIN|g" \
    -e "s|@STANDALONE@|$STANDALONE|g" \
    "$WRAPPER_TMP" > "$PREFIX/bin/$INSTALL_NAME"
chmod +x "$PREFIX/bin/$INSTALL_NAME"

# Debug helper: shared-service mode without --standalone injection
cat > "$PREFIX/bin/opencode-shared" <<'SHARED'
#!/data/data/com.termux/files/usr/bin/sh
export OPENCODE_STANDALONE=0
exec "$(dirname "$0")/opencode" "$@"
SHARED
chmod +x "$PREFIX/bin/opencode-shared"

log "Done. Verifying: $INSTALL_NAME --version"
WRAPPER_VERSION="$("$PREFIX/bin/$INSTALL_NAME" --version 2>&1)" \
  || WRAPPER_VERSION=""
echo "$WRAPPER_VERSION" | grep -qF "$OPENCODE_VERSION" || {
  warn "Installed wrapper reports '$WRAPPER_VERSION', expected $OPENCODE_VERSION."
  if restore_last_good; then
    warn "Rolled back to last-known-good binary."
    "$PREFIX/bin/$INSTALL_NAME" --version 2>&1 || true
  fi
  die "Post-install --version gate failed."
}
log "Verified: $WRAPPER_VERSION"
# Gate 2 (offline, deterministic): `run --help` proves the Node runtime
# boots and arg parsing works — no network or auth involved.
run_with_timeout 60 "$PREFIX/bin/$INSTALL_NAME" run --help >/dev/null 2>&1 || {
  warn "Post-install 'opencode run --help' gate failed."
  if restore_last_good; then
    warn "Rolled back to last-known-good binary."
    "$PREFIX/bin/$INSTALL_NAME" --version 2>&1 || true
  fi
  die "Post-install run --help gate failed."
}
log "Verified: opencode run --help exits 0"
# Gate 3 (opt-in): a real networked run. Off by default — an offline phone
# or expired auth must never look like a broken binary.
case "$OPENCODE_RUN_SMOKE" in
  1|true|yes)
    log "Running opt-in networked smoke test..."
    if ! run_with_timeout 120 "$PREFIX/bin/$INSTALL_NAME" run \
        "Reply with exactly: PONG" 2>&1 | grep -q "PONG"; then
      warn "Networked smoke test failed."
      if restore_last_good; then
        warn "Rolled back to last-known-good binary."
      fi
      die "Networked smoke test failed (OPENCODE_RUN_SMOKE=1)."
    fi
    log "Verified: networked run returned PONG"
    ;;
esac

cat <<'MSG'

Install complete. Verify:
  opencode --version
  opencode run "say hi"

Outbound HTTPS goes through the Python proxy on 127.0.0.1:8080 because
Node/c-ares cannot use musl DNS on Android. The wrapper starts the proxy
if needed. Plain `opencode` (TUI) attaches to the shared service when one
is running; `opencode run ...` gets --standalone by default
(OPENCODE_STANDALONE=0 or `opencode-shared` forces shared mode).

Formatter on Termux: the built-in prettier formatter cannot spawn
(`#!/usr/bin/env node` shebangs break under the musl wrapper). Run
`sh scripts/enable-formatter.sh` once to install a global prettier and
point opencode at it via node directly.

Migrating from v1 or the side-by-side setup: `sh scripts/remove-v1.sh`
MSG
