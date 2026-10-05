#!/data/data/com.termux/files/usr/bin/sh
# auto-update.sh — unattended daily update for OpenCode v2 on Termux.
#
# Runs check-update.sh with --yes: when the installed version is behind the
# official npm channel (opencode.ai update API), re-runs install.sh to
# download, patchelf and reinstall the musl binary. Never downgrades.
#
# Scheduled via Termux:API (see docs/INSTALL.md):
#   termux-job-scheduler --job-id 7802 --period-ms 86400000 \
#     --network unmetered --persisted true \
#     -s /data/data/com.termux/files/home/GitHub/opencode2-termux-musl/scripts/auto-update.sh
#
# Every run appends to ~/.opencode-auto-update.log (override with
# OPENCODE_AUTO_UPDATE_LOG) — Android runs this unattended, so without a
# log a failed check/install is invisible.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${OPENCODE_AUTO_UPDATE_LOG:-$HOME/.opencode-auto-update.log}"
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') auto-update start ==="
rc=0
"$SCRIPT_DIR/check-update.sh" --yes || rc=$?
echo "=== $(date '+%F %T') auto-update exit $rc ==="
exit "$rc"
