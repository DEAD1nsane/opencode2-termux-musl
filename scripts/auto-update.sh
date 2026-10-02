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
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/check-update.sh" --yes
