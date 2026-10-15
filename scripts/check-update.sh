#!/bin/sh
# check-update.sh — check for a newer OpenCode v2 release.
#
# v2 ships via the npm channel only (opencode.ai update API); GitHub
# anomalyco/opencode tags are still v1.x. Compares the installed
# `opencode --version` against the latest npm version and, with --yes,
# re-runs install.sh when behind.
#
# Usage:
#   ./scripts/auto-update.sh           # unattended entrypoint (this + --yes)
#   ./scripts/check-update.sh          # check only, notify if behind (exit 2)
#   ./scripts/check-update.sh --yes    # check + re-run install.sh if behind
#   ./scripts/check-update.sh --rollback  # restore last-known-good binary
#   ./scripts/check-update.sh --status    # show last-run status + job state
#
# Rollback boundary: --yes pins OPENCODE_VERSION to the resolved release so
# the installer cannot drift to a newer upstream build mid-run, and the
# installer itself stages the new binary (.new), smoke-tests it (--version
# + `run --help`), and only then promotes it — keeping the previous binary
# as .last-good. If post-install verification fails here, the last-good
# binary is restored automatically.
#
# Failsafe: every outcome (up-to-date, pending, updating, failed) is
# recorded to STATUS_FILE (default ~/.opencode-update-status, override
# with OPENCODE_UPDATE_STATUS) so a killed or network-starved run is
# visible via --status instead of silent. Failures also fire a
# termux-notification (+ toast fallback) naming the installed version,
# the reason, and that the periodic job retries on its next run.
#
# Exit codes: 0 = up to date, 1 = error, 2 = update available.
#
# Periodic auto-update (every 6h — not at a fixed time; needs Termux:API):
#   termux-job-scheduler --job-id 7802 --period-ms 21600000 \
#     --network any --persisted true \
#     -s /path/to/opencode2-termux-musl/scripts/auto-update.sh
#
# The check-only notification adapts to whether that periodic job exists:
# if it does, the notification says the update is applied automatically;
# if not, it points at auto-update.sh — never at a manual install.sh run.
#
# Requires: curl.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install.sh"
CMD=opencode
UPDATE_API="${UPDATE_API:-https://opencode.ai/update/api/latest/cli/npm}"
NPM_FALLBACK="https://registry.npmjs.org/@opencode%2Fcli/latest"
LIBEXEC="${PREFIX:-/data/data/com.termux/files/usr}/libexec/opencode"
LOG_FILE="${OPENCODE_AUTO_UPDATE_LOG:-$HOME/.opencode-auto-update.log}"
STATUS_FILE="${OPENCODE_UPDATE_STATUS:-$HOME/.opencode-update-status}"
# Time-boxed + retried: on mobile networks an unbounded curl hangs until
# the job system kills us — which used to leave no exit line, no status,
# and no notification (silent non-update).
CURL_CHECK="curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 5 --retry-all-errors"
APPLY=0
ROLLBACK=0
SHOW_STATUS=0

for arg in "$@"; do
  case "$arg" in
    --yes) APPLY=1 ;;
    --rollback) ROLLBACK=1 ;;
    --status) SHOW_STATUS=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

notify() {
  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --id "opencode-update" --action "/data/data/com.termux/files/usr/bin/am start -n com.termux/com.termux.app.TermuxActivity" --title "opencode update" --content "$1" 2>/dev/null || true
  fi
}

# Loud failure path: high-priority + sound (a default notification only
# vibrates and flashes a banner — too easy to miss for a failed update),
# plus toast fallback (both need Termux:API; when absent the status file
# + log + stderr are the signal). Not --ongoing: a pinned notification
# can't be swiped away and would need termux-notification-remove to clear.
fail_notify() {
  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --id "opencode-update" --priority high --sound --action "/data/data/com.termux/files/usr/bin/am start -n com.termux/com.termux.app.TermuxActivity" --title "opencode update FAILED" --content "$1" 2>/dev/null || true
  fi
  if command -v termux-toast >/dev/null 2>&1; then
    termux-toast "$1" 2>/dev/null || true
  fi
}

set_status() {
  printf '%s | %s | %s\n' "$(date '+%F %T')" "$1" "$2" >"$STATUS_FILE" 2>/dev/null || true
}

# Does the periodic every-6h auto-update job exist? The check-only
# notification must not send people to manually re-run install.sh — with
# the job enabled, updates apply on their own; without it, the only
# instruction should be to enable auto-update.sh (the docs' step 1).
periodic_job_enabled() {
  # `timeout` guards the API call: termux-job-scheduler talks to the
  # Termux:API app over a socket and can block indefinitely when that
  # bridge is unavailable (e.g. inside the unattended job itself),
  # wedging the whole run with no output.
  if command -v termux-job-scheduler >/dev/null 2>&1 \
    && timeout 10 termux-job-scheduler -p 2>/dev/null | grep -q "auto-update\.sh"; then
    return 0
  fi
  return 1
}

if [ "$SHOW_STATUS" -eq 1 ]; then
  if [ -f "$STATUS_FILE" ]; then
    echo "status: $(cat "$STATUS_FILE")"
  else
    echo "status: no auto-update run recorded yet."
  fi
  if periodic_job_enabled; then
    echo "periodic job: enabled (every 6h, not at a fixed time)."
  else
    echo "periodic job: NOT found — enable it (see docs/INSTALL.md):"
    echo "  termux-job-scheduler --job-id 7802 --period-ms 21600000 \\"
    echo "    --network any --persisted true -s \"$SCRIPT_DIR/auto-update.sh\""
  fi
  if [ -f "$LOG_FILE" ]; then
    echo "--- last log lines ($LOG_FILE) ---"
    tail -n 15 "$LOG_FILE"
  fi
  exit 0
fi

if [ "$ROLLBACK" -eq 1 ]; then
  LASTGOOD="$LIBEXEC/opencode-v2-musl.bin.last-good"
  [ -f "$LASTGOOD" ] || { echo "No last-known-good binary ($LASTGOOD)." >&2; exit 1; }
  cp -p "$LASTGOOD" "$LIBEXEC/opencode-v2-musl.bin"
  chmod 755 "$LIBEXEC/opencode-v2-musl.bin"
  [ -f "$LIBEXEC/VERSION.last-good" ] && cp -p "$LIBEXEC/VERSION.last-good" "$LIBEXEC/VERSION"
  [ -f "$LIBEXEC/SHA256.last-good" ] && cp -p "$LIBEXEC/SHA256.last-good" "$LIBEXEC/SHA256"
  restored="$("$CMD" --version 2>/dev/null || echo FAILED)"
  echo "Restored last-known-good binary: $restored"
  echo "$restored" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' || { echo "Restored binary fails --version." >&2; exit 1; }
  set_status "rolled-back" "restored=$restored"
  notify "opencode rolled back to $restored."
  exit 0
fi

installed="$("$CMD" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$installed" ]; then
  set_status "failed" "could not read installed version; will retry next periodic run"
  fail_notify "opencode update check failed: cannot read installed version. Will retry automatically."
  echo "Could not read installed opencode version." >&2
  exit 1
fi
set_status "checking" "installed=$installed resolving latest..."
META=$($CURL_CHECK "$UPDATE_API" 2>/dev/null || true)
latest=$(printf '%s' "$META" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
# Fall back to the npm registry when the opencode.ai endpoint is down —
# /latest has the same JSON shape ({"version":"x.y.z",...}).
if [ -z "$latest" ]; then
  META=$($CURL_CHECK "$NPM_FALLBACK" 2>/dev/null || true)
  latest=$(printf '%s' "$META" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
fi
if [ -z "$latest" ]; then
  set_status "failed" "installed=$installed could not resolve latest (network?); will retry next periodic run; see $LOG_FILE"
  fail_notify "opencode update check failed (network?): still on $installed. Retries automatically — no action needed. See log: .opencode-auto-update.log"
  echo "Could not resolve latest version from $UPDATE_API." >&2
  exit 1
fi
latest="${latest#v}"

if [ "$installed" = "$latest" ]; then
  set_status "up-to-date" "installed=$installed latest=$latest"
  echo "$CMD is up to date ($installed)."
  exit 0
fi

# Only treat latest > installed as an update. If the installed build
# is newer (e.g. manually installed pre-release), never "update" —
# that path would downgrade a working installation.
oldest="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)"
if [ "$oldest" = "$latest" ]; then
  set_status "up-to-date" "installed=$installed newer than release $latest; nothing to do"
  echo "Installed $installed is newer than latest release $latest; nothing to do."
  exit 0
fi

auto_job=0
periodic_job_enabled && auto_job=1

if [ "$APPLY" -eq 0 ]; then
  if [ "$auto_job" -eq 1 ]; then
    set_status "update-pending" "installed=$installed latest=$latest; periodic every-6h job applies it"
    echo "Update available: installed $installed, latest $latest (periodic every-6h job applies it)."
  else
    set_status "update-pending" "installed=$installed latest=$latest; periodic job NOT enabled"
    echo "Update available: installed $installed, latest $latest."
    echo "No periodic auto-update job found — enable it: scripts/auto-update.sh (see docs/INSTALL.md)."
  fi
else
  echo "Update available: installed $installed, latest $latest."
fi

if [ "$APPLY" -eq 1 ]; then
  set_status "updating" "installed=$installed latest=$latest downloading (~84MB, resumes + retries on bad networks)..."
  notify "opencode $installed -> $latest: downloading (~84MB, resumes on flaky networks)..."
  if [ -x "$INSTALLER" ]; then
    echo "Applying update via $INSTALLER (pinned to $latest)..."
    # Pin the resolved version: the installer must install exactly this
    # release, not whatever "latest" points at by the time it runs.
    if OPENCODE_VERSION="$latest" "$INSTALLER"; then
      # Post-install verification (defense in depth — the installer gates
      # promotion itself, this catches anything that broke after promote).
      new_version="$("$CMD" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      if [ "$new_version" = "$latest" ] && "$CMD" run --help >/dev/null 2>&1; then
        set_status "updated" "installed=$latest (was $installed)"
        notify "opencode updated to $latest."
        exit 0
      fi
      echo "Post-install verification failed (reports '${new_version:-nothing}')." >&2
      set_status "failed" "installed=$installed latest=$latest post-install verification failed; restoring last-good; retries next periodic run"
    else
      echo "Installer failed (likely network); live binary untouched (staged promote)." >&2
      set_status "failed" "installed=$installed latest=$latest download/install failed (network?); live binary untouched; retries next periodic run; see $LOG_FILE"
    fi
    # Restore the last-known-good binary when anything above failed.
    LASTGOOD="$LIBEXEC/opencode-v2-musl.bin.last-good"
    if [ -f "$LASTGOOD" ]; then
      echo "Restoring last-known-good binary..." >&2
      cp -p "$LASTGOOD" "$LIBEXEC/opencode-v2-musl.bin"
      chmod 755 "$LIBEXEC/opencode-v2-musl.bin"
      [ -f "$LIBEXEC/VERSION.last-good" ] && cp -p "$LIBEXEC/VERSION.last-good" "$LIBEXEC/VERSION"
      [ -f "$LIBEXEC/SHA256.last-good" ] && cp -p "$LIBEXEC/SHA256.last-good" "$LIBEXEC/SHA256"
      restored="$("$CMD" --version 2>/dev/null || echo FAILED)"
      set_status "failed" "installed=$installed latest=$latest FAILED ($restored still live); retries next periodic run; see $LOG_FILE"
      fail_notify "opencode auto-update to $latest failed (network?): still on $restored. Retries automatically — no action needed."
    else
      set_status "failed" "installed=$installed latest=$latest FAILED and no last-good copy; retry manually: sh install.sh"
      fail_notify "opencode auto-update to $latest failed (network?): still on $installed. Will retry automatically; or run sh install.sh manually."
    fi
    exit 1
  else
    set_status "failed" "installer missing at $INSTALLER"
    echo "Cannot auto-apply: $INSTALLER not found next to this script." >&2
    echo "Update manually: sh install.sh" >&2
    exit 2
  fi
fi

if [ "$auto_job" -eq 1 ]; then
  notify "opencode $installed -> $latest available. Applied automatically by the periodic job."
else
  notify "opencode $installed -> $latest available. Enable scripts/auto-update.sh for periodic updates (see docs/INSTALL.md)."
fi
exit 2
