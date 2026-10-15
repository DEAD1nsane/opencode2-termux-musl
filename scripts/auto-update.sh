#!/data/data/com.termux/files/usr/bin/sh
# auto-update.sh — periodic (every 6h, not at a fixed time) update job.
#
# Runs check-update.sh with --yes: when the installed version is behind the
# official npm channel (opencode.ai update API), re-runs install.sh to
# download, patchelf and reinstall the musl binary. Never downgrades.
#
# Enabled once via Termux:API (see docs/INSTALL.md) — after that Android
# fires it roughly every 6h (exact timing is up to the OS, hence not
# "scheduled" at a fixed hour):
#   termux-job-scheduler --job-id 7802 --period-ms 21600000 \
#     --network any --persisted true \
#     -s /data/data/com.termux/files/home/GitHub/opencode2-termux-musl/scripts/auto-update.sh
#
# Every run appends to ~/.opencode-auto-update.log (override with
# OPENCODE_AUTO_UPDATE_LOG) and records a one-line outcome to
# ~/.opencode-update-status (override with OPENCODE_UPDATE_STATUS;
# read it with scripts/check-update.sh --status). Android runs this
# unattended, so without the log + status + failure notification a
# network-starved or killed run is invisible.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${OPENCODE_AUTO_UPDATE_LOG:-$HOME/.opencode-auto-update.log}"
STATUS="${OPENCODE_UPDATE_STATUS:-$HOME/.opencode-update-status}"
exec >>"$LOG" 2>&1
NOW="$(date '+%F %T')"
# A previous run with a start line but no exit line died mid-flight
# (killed by the OS, reboot, or a hung network fetch) — say so loudly
# instead of staying silent; the live binary was never touched mid-stage.
if [ -f "$LOG" ]; then
  starts=$(grep -c "auto-update start" "$LOG" 2>/dev/null || echo 0)
  exits=$(grep -c "auto-update exit" "$LOG" 2>/dev/null || echo 0)
  if [ "${starts:-0}" -gt "${exits:-0}" ]; then
    still_on="$(opencode --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    echo "=== $NOW auto-update: NOTE previous run died without finishing (likely bad network or OS kill); still on ${still_on:-unknown}, retrying now ==="
    printf '%s | %s | %s\n' "$NOW" "failed" "previous run died mid-flight (network/OS kill); still on ${still_on:-unknown}; retrying now" >"$STATUS" 2>/dev/null || true
    if command -v termux-notification >/dev/null 2>&1; then
      termux-notification --id "opencode-update" --priority high --sound --action "/data/data/com.termux/files/usr/bin/am start -n com.termux/com.termux.app.TermuxActivity" --title "opencode update FAILED" --content "Previous auto-update died mid-run (bad network?). Still on ${still_on:-unknown} — retrying now." 2>/dev/null || true
    fi
  fi
fi
echo "=== $NOW auto-update start ==="
rc=0
"$SCRIPT_DIR/check-update.sh" --yes || rc=$?
echo "=== $(date '+%F %T') auto-update exit $rc ==="
exit "$rc"
