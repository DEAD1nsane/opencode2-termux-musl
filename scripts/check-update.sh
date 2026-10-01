#!/bin/sh
# check-update.sh — check for a newer OpenCode v2 release.
#
# v2 ships via the npm channel only (opencode.ai update API); GitHub
# anomalyco/opencode tags are still v1.x. Compares the installed
# `opencode --version` against the latest npm version and, with --yes,
# re-runs install.sh when behind.
#
# Usage:
#   ./scripts/check-update.sh          # check only, notify if behind (exit 2)
#   ./scripts/check-update.sh --yes    # check + re-run install.sh if behind
#
# Exit codes: 0 = up to date, 1 = error, 2 = update available.
#
# Unattended daily check (needs the Termux:API app):
#   termux-job-scheduler --job-id 7802 --period-ms 86400000 \
#     --network unmetered --persisted true \
#     -s /path/to/opencode2-termux-musl/scripts/check-update.sh
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

echo "Update available: installed $installed, latest $latest."

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

notify "opencode $installed -> $latest available. Re-run install.sh to update."
exit 2
