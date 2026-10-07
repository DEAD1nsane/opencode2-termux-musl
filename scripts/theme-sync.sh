#!/bin/sh
# theme-sync.sh — day/night theme mode sync for OpenCode on Termux.
#
# Why this exists: cli.json "theme.mode": "system" follows the TERMINAL
# background (OSC 11 / Mode 2031), not the Android system day/night mode.
# Termux's background is fixed by ~/.termux/colors.properties, so "system"
# always resolves to the same variant (dark on a black background) and never
# tracks the phone's day/night schedule. Manually setting mode to "light" or
# "dark" works because it bypasses terminal detection entirely.
#
# What it does: sets theme.mode in ~/.config/opencode/cli.json to "light"
# between LIGHT_START (default 07:00) and LIGHT_END (default 19:00) local
# time, otherwise "dark". Theme NAME is preserved; only "mode" is rewritten
# (with a .bak-theme-sync backup on change). It does NOT try to read the
# Android UiMode — Termux is denied without privileged permission:
#   settings get secure ui_night_mode -> INTERACT_ACROSS_USERS denied
#   cmd uimode night                  -> MODIFY_DAY_NIGHT_MODE denied
# Time of day is the only permission-free day/night signal.
#
# Usage:
#   sh scripts/theme-sync.sh                 # apply based on current time
#   sh scripts/theme-sync.sh --check         # print what would change
#   sh scripts/theme-sync.sh --status        # current config + computed mode
#   sh scripts/theme-sync.sh --light         # force light mode now
#   sh scripts/theme-sync.sh --dark          # force dark mode now
#   sh scripts/theme-sync.sh --system        # restore mode "system"
#   sh scripts/theme-sync.sh --light-start 06:30 --light-end 18:30
#
# Env knobs:
#   THEME_SYNC_LIGHT_START=07:00  THEME_SYNC_LIGHT_END=19:00
#   THEME_SYNC_CONFIG=/path/to/cli.json  (default ~/.config/opencode/cli.json)
#   THEME_SYNC_NOTIFY=1  (fire a termux-notification on change)
#
# Unattended (Termux:API — schedule once; uses job id 7803 to avoid the
# auto-update job 7802):
#   termux-job-scheduler --job-id 7803 --period-ms 3600000 \
#     --persisted true \
#     -s "$HOME/GitHub/opencode2-termux-musl/scripts/theme-sync.sh"
# Takes effect on next TUI launch (cli.json is read at startup; a running
# TUI keeps its current mode). Hourly is plenty — mode only flips twice daily.
#
# Requires: python3 (JSON edit). No network, no Termux:API (except notify/job).
#
# Exit codes: 0 = ok (applied or already correct), 1 = error,
#             2 = --check reports a change would be made.

set -e

LIGHT_START="${THEME_SYNC_LIGHT_START:-07:00}"
LIGHT_END="${THEME_SYNC_LIGHT_END:-19:00}"
CFG="${THEME_SYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/cli.json}"
NOTIFY="${THEME_SYNC_NOTIFY:-0}"

FORCE=""
CHECK=0
STATUS_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --light) FORCE="light" ;;
    --dark) FORCE="dark" ;;
    --system) FORCE="system" ;;
    --check) CHECK=1 ;;
    --status) STATUS_ONLY=1 ;;
    --light-start=*) LIGHT_START="${arg#--light-start=}" ;;
    --light-end=*) LIGHT_END="${arg#--light-end=}" ;;
    --config=*) CFG="${arg#--config=}" ;;
    --notify) NOTIFY=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --light-start|--light-end|--config)
      echo "error: $arg needs a value — use $arg=VALUE" >&2; exit 1 ;;
    --light|--dark|--system|--check|--status|--notify)
      ;; # handled above (unreachable, kept for clarity)
    *)
      # positional HH:MM pair: theme-sync.sh [LIGHT_START] [LIGHT_END]
      if [ -z "$pos1" ]; then pos1="$arg"; else pos2="$arg"; fi
      ;;
  esac
done
[ -n "$pos1" ] && LIGHT_START="$pos1"
[ -n "$pos2" ] && LIGHT_END="$pos2"
unset pos1 pos2

# shellcheck disable=SC2034
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 not found (pkg install python)"
[ -f "$CFG" ] || die "config not found: $CFG"

valid_hhmm() {
  case "$1" in
    [0-2][0-9]:[0-5][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}
valid_hhmm "$LIGHT_START" || die "bad light-start: $LIGHT_START (want HH:MM)"
valid_hhmm "$LIGHT_END" || die "bad light-end: $LIGHT_END (want HH:MM)"

to_min() { # HH:MM -> minutes since midnight
  h="${1%%:*}"; m="${1##*:}"
  h="${h#0}"; m="${m#0}"
  [ -z "$h" ] && h=0; [ -z "$m" ] && m=0
  echo $(($h * 60 + $m))
}

if [ -n "$FORCE" ]; then
  WANT="$FORCE"
else
  NOW_HM="$(date '+%H:%M')"
  now="$(to_min "$NOW_HM")"
  start="$(to_min "$LIGHT_START")"
  end="$(to_min "$LIGHT_END")"
  if [ "$start" -le "$end" ]; then
    if [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]; then WANT="light"; else WANT="dark"; fi
  else
    # overnight window (e.g. 19:00-07:00)
    if [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]; then WANT="light"; else WANT="dark"; fi
  fi
fi

CURRENT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("theme",{}).get("mode","?"))' "$CFG" 2>/dev/null || echo "?")"
NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("theme",{}).get("name","?"))' "$CFG" 2>/dev/null || echo "?")"

if [ "$STATUS_ONLY" -eq 1 ]; then
  echo "config: $CFG"
  echo "theme: $NAME / mode: $CURRENT (want: $WANT, light window $LIGHT_START-$LIGHT_END)"
  exit 0
fi

if [ "$CURRENT" = "$WANT" ]; then
  echo "theme-sync: already $WANT ($NAME) — nothing to do."
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "theme-sync: would set mode $CURRENT -> $WANT ($NAME, light window $LIGHT_START-$LIGHT_END)."
  exit 2
fi

cp "$CFG" "$CFG.bak-theme-sync"

WANT_EXPORT="$WANT" python3 - "$CFG" <<'PY'
import json, os, sys
path = sys.argv[1]
want = os.environ["WANT_EXPORT"]
with open(path) as f:
    cfg = json.load(f)
theme = cfg.get("theme")
if not isinstance(theme, dict):
    theme = {}
    cfg["theme"] = theme
theme["mode"] = want
theme.setdefault("name", "opencode")
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"theme-sync: mode {want} written to {path} (backup: {path}.bak-theme-sync)")
PY

if [ "$NOTIFY" = "1" ] && command -v termux-notification >/dev/null 2>&1; then
  termux-notification --title "opencode theme" --content "Switched to $WANT mode ($NAME)." 2>/dev/null || true
fi

echo "Restart the TUI to pick it up (cli.json is read at startup)."
