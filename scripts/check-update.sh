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
#
# Exit codes: 0 = up to date, 1 = error, 2 = update available.
#
# Unattended auto-update (check + apply; needs the Termux:API app):
#   termux-job-scheduler --job-id 7802 --period-ms 21600000 \
#     --network any --persisted true \
#     -s /path/to/opencode2-termux-musl/scripts/auto-update.sh
#
# The check-only notification adapts to whether that job is scheduled:
# if it is, the notification says the update is applied automatically;
# if not, it points at auto-update.sh — never at a manual install.sh run.
#
# Requires: curl.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SCRIPT_DIR/../install.sh"
CMD=opencode
UPDATE_API="${UPDATE_API:-https://opencode.ai/update/api/latest/cli/npm}"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --yes) APPLY=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

notify() {
  if command -v termux-notification >/dev/null 2>&1; then
    termux-notification --title "opencode update" --content "$1" 2>/dev/null || true
  fi
}

installed="$("$CMD" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$installed" ] || { echo "Could not read installed opencode version." >&2; exit 1; }
META=$(curl -fsSL "$UPDATE_API" 2>/dev/null || true)
latest=$(printf '%s' "$META" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
[ -n "$latest" ] || { echo "Could not resolve latest version from $UPDATE_API." >&2; exit 1; }
latest="${latest#v}"

if [ "$installed" = "$latest" ]; then
  echo "$CMD is up to date ($installed)."
  exit 0
fi

# Only treat latest > installed as an update. If the installed build
# is newer (e.g. manually installed pre-release), never "update" —
# that path would downgrade a working installation.
oldest="$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | head -1)"
if [ "$oldest" = "$latest" ]; then
  echo "Installed $installed is newer than latest release $latest; nothing to do."
  exit 0
fi

# Does the unattended auto-update job exist? The check-only notification
# must not send people to manually re-run install.sh — with the job
# scheduled, updates apply on their own; without it, the only instruction
# should be to schedule auto-update.sh (the docs' step 1).
auto_job_scheduled=0
# `timeout` guards the API call: termux-job-scheduler talks to the
# Termux:API app over a socket and can block indefinitely when that
# bridge is unavailable (e.g. inside the unattended job itself),
# wedging the whole run with no output.
if command -v termux-job-scheduler >/dev/null 2>&1 \
  && timeout 10 termux-job-scheduler -p 2>/dev/null | grep -q "auto-update\.sh"; then
  auto_job_scheduled=1
fi

if [ "$APPLY" -eq 0 ]; then
  if [ "$auto_job_scheduled" -eq 1 ]; then
    echo "Update available: installed $installed, latest $latest (auto-update job applies it)."
  else
    echo "Update available: installed $installed, latest $latest."
    echo "No auto-update job scheduled — run: scripts/auto-update.sh (see docs/INSTALL.md)."
  fi
else
  echo "Update available: installed $installed, latest $latest."
fi

if [ "$APPLY" -eq 1 ]; then
  notify "opencode $installed -> $latest available. Auto-updating..."
  if [ -x "$INSTALLER" ]; then
    echo "Applying update via $INSTALLER..."
    "$INSTALLER"
    rc=$?
    if [ $rc -eq 0 ]; then
      notify "opencode updated to $latest."
    else
      notify "opencode auto-update failed (exit $rc). Re-run $INSTALLER manually."
    fi
    exit $rc
  else
    echo "Cannot auto-apply: $INSTALLER not found next to this script." >&2
    echo "Update manually: sh install.sh" >&2
    exit 2
  fi
fi

if [ "$auto_job_scheduled" -eq 1 ]; then
  notify "opencode $installed -> $latest available. Applied automatically by the update job."
else
  notify "opencode $installed -> $latest available. Schedule scripts/auto-update.sh for unattended updates (see docs/INSTALL.md)."
fi
exit 2
