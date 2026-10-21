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
# (with a .bak-theme-sync backup on change). It ALSO flips the Termux
# terminal background in ~/.termux/colors.properties to match (white by day,
# black by night) and night-mode in ~/.termux/termux.properties
# (false by day, true by night, deprecated use-black-ui removed) and runs
# termux-reload-settings, so the resize gap behind
# the TUI is the same color as the theme — no black flash in light mode.
# NOTE: night-mode needs a force-stop + reopen to take effect; colors apply live.
#
# PALETTE SWAP: background/foreground alone is not enough for day mode — the
# 16 ANSI colors are tuned for a black background, so on white the dark
# palette's yellow is 1.07:1 and its white slots (color6/7/14/15) are 1.00:1,
# i.e. invisible. So this script also swaps the whole palette: it copies the
# cursor + color0..color15 values from
#   ~/.termux/colors-light.properties  (day)
#   ~/.termux/colors-dark.properties   (night)
# into ~/.termux/colors.properties, key by key, leaving comments intact.
# Both palette files are the source of truth — edit those, not the live file,
# or the next scheduled run will revert you. background/foreground still come
# from THEME_SYNC_LIGHT_BG/FG and THEME_SYNC_DARK_BG/FG, so those env knobs
# keep working and override whatever the palette file says.
# If a palette file is missing, only background/foreground are touched
# (previous behaviour).
# It does NOT try to read the
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
#   sh scripts/theme-sync.sh --system        # restore mode "system" (termux left alone)
#   sh scripts/theme-sync.sh --light-start=06:30 --light-end=18:30
#   sh scripts/theme-sync.sh --no-termux     # opencode mode only, leave Termux colors alone
#
# Env knobs:
#   THEME_SYNC_LIGHT_START=07:00  THEME_SYNC_LIGHT_END=19:00
#   THEME_SYNC_CONFIG=/path/to/cli.json  (default ~/.config/opencode/cli.json)
#   THEME_SYNC_NOTIFY=1  (fire a termux-notification on change)
#   THEME_SYNC_TERMUX=1|0  (default 1 — also flip Termux background)
#   THEME_SYNC_TERMUX_COLORS=/path/to/colors.properties
#     (default ~/.termux/colors.properties)
#   THEME_SYNC_LIGHT_BG=#ffffff  THEME_SYNC_LIGHT_FG=#1a1a1a
#   THEME_SYNC_DARK_BG=#000000  THEME_SYNC_DARK_FG=#ffffff
#   THEME_SYNC_PALETTE_LIGHT=$HOME/.termux/colors-light.properties
#   THEME_SYNC_PALETTE_DARK=$HOME/.termux/colors-dark.properties
#   THEME_SYNC_PALETTE=0   (disable the palette swap; bg/fg only, as before)
#
# Unattended (Termux:API — schedule once; uses job id 7803 to avoid the
# auto-update job 7802):
#   termux-job-scheduler --job-id 7803 --period-ms 900000 \
#     --persisted true \
#     -s "$HOME/GitHub/opencode2-termux-musl/scripts/theme-sync.sh"
# 900000ms (15min) is Android's minimum job period — the flip lands within
# ~15min after the boundary (Doze can delay further), never exactly on it.
# A notification fires on every flip: restart the TUI + force-stop Termux.
# Takes effect on next TUI launch (cli.json is read at startup; a running
# TUI keeps its current mode).
#
# Requires: python3 (JSON edit). No network, no Termux:API (except notify/job).
#
# Exit codes: 0 = ok (applied or already correct), 1 = error,
#             2 = --check reports a change would be made.

set -e

LIGHT_START="${THEME_SYNC_LIGHT_START:-07:00}"
LIGHT_END="${THEME_SYNC_LIGHT_END:-19:00}"
CFG="${THEME_SYNC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/cli.json}"
NOTIFY="${THEME_SYNC_NOTIFY:-1}"
DO_TERMUX="${THEME_SYNC_TERMUX:-1}"
TERMCOLORS="${THEME_SYNC_TERMUX_COLORS:-$HOME/.termux/colors.properties}"
TERMPROPS="${THEME_SYNC_TERMUX_PROPS:-$HOME/.termux/termux.properties}"
LIGHT_BG="${THEME_SYNC_LIGHT_BG:-#ffffff}"
LIGHT_FG="${THEME_SYNC_LIGHT_FG:-#000000}"
DARK_BG="${THEME_SYNC_DARK_BG:-#000000}"
DARK_FG="${THEME_SYNC_DARK_FG:-#ffffff}"
PAL_LIGHT="${THEME_SYNC_PALETTE_LIGHT:-$HOME/.termux/colors-light.properties}"
PAL_DARK="${THEME_SYNC_PALETTE_DARK:-$HOME/.termux/colors-dark.properties}"
DO_PALETTE="${THEME_SYNC_PALETTE:-1}"

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
    --termux) DO_TERMUX=1 ;;
    --no-termux) DO_TERMUX=0 ;;
    --no-palette) DO_PALETTE=0 ;;
    --light-start=*) LIGHT_START="${arg#--light-start=}" ;;
    --light-end=*) LIGHT_END="${arg#--light-end=}" ;;
    --config=*) CFG="${arg#--config=}" ;;
    --termux-colors=*) TERMCOLORS="${arg#--termux-colors=}" ;;
    --notify) NOTIFY=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --light-start|--light-end|--config|--termux-colors)
      echo "error: $arg needs a value — use $arg=VALUE" >&2; exit 1 ;;
    --light|--dark|--system|--check|--status|--notify|--termux|--no-termux|--no-palette)
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

# --- Termux terminal background (kills the resize flash) ---
# background/foreground are flipped, and the whole ANSI palette is copied from
# colors-light.properties / colors-dark.properties for the target mode.
# --system leaves Termux alone (mode "system" follows whatever is set).
TERM_BG=""
TERM_FG=""
TERM_WANT_BG=""
TERM_WANT_FG=""
if [ "$DO_TERMUX" = "1" ] && [ "$FORCE" != "system" ] && [ -f "$TERMCOLORS" ]; then
  TERM_BG="$(sed -n 's/^background=//p' "$TERMCOLORS" | head -1)"
  TERM_FG="$(sed -n 's/^foreground=//p' "$TERMCOLORS" | head -1)"
  if [ "$WANT" = "light" ]; then
    TERM_WANT_BG="$LIGHT_BG"; TERM_WANT_FG="$LIGHT_FG"
  else
    TERM_WANT_BG="$DARK_BG"; TERM_WANT_FG="$DARK_FG"
  fi
fi
# Both keys are checked — foreground-only drift used to go unrepaired.
TERM_NEED=0
if [ -n "$TERM_WANT_BG" ]; then
  [ "$TERM_BG" != "$TERM_WANT_BG" ] && TERM_NEED=1
  [ "$TERM_FG" != "$TERM_WANT_FG" ] && TERM_NEED=1
fi

# --- Termux ANSI palette (cursor + color0..15) ---
# Without this, day mode keeps the black-background palette: yellow lands at
# 1.07:1 and the white slots at 1.00:1 on white. Missing palette file or
# THEME_SYNC_PALETTE=0 degrades to the old background/foreground-only behaviour.
PAL_KEYS="cursor color0 color1 color2 color3 color4 color5 color6 color7 \
color8 color9 color10 color11 color12 color13 color14 color15"
PAL_SRC=""
PAL_DRIFT=""
PAL_NEED=0
if [ "$DO_TERMUX" = "1" ] && [ "$DO_PALETTE" = "1" ] && [ "$FORCE" != "system" ] && [ -f "$TERMCOLORS" ]; then
  if [ "$WANT" = "light" ]; then PAL_SRC="$PAL_LIGHT"; else PAL_SRC="$PAL_DARK"; fi
  if [ -f "$PAL_SRC" ]; then
    for key in $PAL_KEYS; do
      want="$(sed -n "s/^${key}=//p" "$PAL_SRC" | head -1 | tr -d '[:space:]')"
      [ -n "$want" ] || continue
      have="$(sed -n "s/^${key}=//p" "$TERMCOLORS" | head -1 | tr -d '[:space:]')"
      if [ "$have" != "$want" ]; then
        PAL_NEED=1
        PAL_DRIFT="$PAL_DRIFT ${key}:${have:-unset}->${want}"
      fi
    done
  fi
fi

# --- Termux night-mode (extra-keys bar + drawer follow this, needs restart) ---
TERM_WANT_NIGHT=""
PROP_NIGHT=""
if [ "$DO_TERMUX" = "1" ] && [ "$FORCE" != "system" ] && [ -f "$TERMPROPS" ]; then
  if [ "$WANT" = "light" ]; then TERM_WANT_NIGHT="false"; else TERM_WANT_NIGHT="true"; fi
  PROP_NIGHT="$(sed -n 's/^[[:space:]]*night-mode[[:space:]]*=[[:space:]]*//p' "$TERMPROPS" | tail -1 | tr -d '[:space:]')"
fi
NIGHT_NEED=0
if [ -n "$TERM_WANT_NIGHT" ] && [ "$PROP_NIGHT" != "$TERM_WANT_NIGHT" ]; then NIGHT_NEED=1; fi

COLORS_BACKED_UP=0
backup_colors() { # one .bak-theme-sync per run, taken before the first edit
  [ "$COLORS_BACKED_UP" = "1" ] && return 0
  [ -f "$TERMCOLORS" ] || return 0
  cp "$TERMCOLORS" "$TERMCOLORS.bak-theme-sync"
  COLORS_BACKED_UP=1
}

apply_palette() { # copy cursor + color0..15 from $PAL_SRC into $TERMCOLORS
  [ -f "$PAL_SRC" ] || return 0
  backup_colors
  for key in $PAL_KEYS; do
    want="$(sed -n "s/^${key}=//p" "$PAL_SRC" | head -1 | tr -d '[:space:]')"
    [ -n "$want" ] || continue
    if grep -q "^${key}=" "$TERMCOLORS"; then
      sed -i "s|^${key}=.*|${key}=${want}|" "$TERMCOLORS"
    else
      printf '%s=%s\n' "$key" "$want" >> "$TERMCOLORS"
    fi
  done
  echo "theme-sync: palette <- $PAL_SRC"
  echo "theme-sync: palette changed:$PAL_DRIFT"
}

apply_termux() {
  # $1 = bg, $2 = fg
  [ -f "$TERMCOLORS" ] || return 0
  backup_colors
  if grep -q '^background=' "$TERMCOLORS"; then
    sed -i "s|^background=.*|background=$1|" "$TERMCOLORS"
  else
    printf 'background=%s\n' "$1" >> "$TERMCOLORS"
  fi
  if grep -q '^foreground=' "$TERMCOLORS"; then
    sed -i "s|^foreground=.*|foreground=$2|" "$TERMCOLORS"
  else
    printf 'foreground=%s\n' "$2" >> "$TERMCOLORS"
  fi
  echo "theme-sync: termux background $TERM_BG -> $1 (backup: $TERMCOLORS.bak-theme-sync)"
}

apply_nightmode() {
  # $1 = true|false — also drops deprecated use-black-ui (forces dark, confuses).
  [ -f "$TERMPROPS" ] || return 0
  cp "$TERMPROPS" "$TERMPROPS.bak-theme-sync"
  sed -i '/^[[:space:]]*use-black-ui[[:space:]]*=/d' "$TERMPROPS"
  if grep -q '^[[:space:]]*night-mode[[:space:]]*=' "$TERMPROPS"; then
    sed -i "s|^[[:space:]]*night-mode[[:space:]]*=.*|night-mode = $1|" "$TERMPROPS"
  else
    printf 'night-mode = %s\n' "$1" >> "$TERMPROPS"
  fi
  echo "theme-sync: termux night-mode $PROP_NIGHT -> $1 (backup: $TERMPROPS.bak-theme-sync)"
}

if [ "$STATUS_ONLY" -eq 1 ]; then
  echo "config: $CFG"
  echo "theme: $NAME / mode: $CURRENT (want: $WANT, light window $LIGHT_START-$LIGHT_END)"
  if [ "$DO_TERMUX" = "1" ]; then
    if [ -n "$TERM_WANT_BG" ]; then
      echo "termux: $TERMCOLORS background $TERM_BG (want: $TERM_WANT_BG)"
      echo "termux: $TERMCOLORS foreground $TERM_FG (want: $TERM_WANT_FG)"
    else
      echo "termux: skipped (missing file or --system)"
    fi
    if [ -n "$PAL_SRC" ] && [ -f "$PAL_SRC" ]; then
      if [ "$PAL_NEED" = "1" ]; then
        echo "termux: palette $PAL_DRIFT (from $PAL_SRC)"
      else
        echo "termux: palette matches $PAL_SRC"
      fi
    else
      echo "termux: palette off (missing $PAL_SRC, or --no-palette)"
    fi
    if [ -n "$TERM_WANT_NIGHT" ]; then
      echo "termux: $TERMPROPS night-mode $PROP_NIGHT (want: $TERM_WANT_NIGHT)"
    fi
  else
    echo "termux: disabled (--no-termux)"
  fi
  exit 0
fi

NEED_OPENCODE=0
[ "$CURRENT" != "$WANT" ] && NEED_OPENCODE=1

if [ "$NEED_OPENCODE" -eq 0 ] && [ "$TERM_NEED" -eq 0 ] && [ "$NIGHT_NEED" -eq 0 ] && [ "$PAL_NEED" -eq 0 ]; then
  echo "theme-sync: already $WANT ($NAME)"
  [ "$DO_TERMUX" = "1" ] && [ -n "$TERM_WANT_BG" ] && echo "theme-sync: termux background already $TERM_BG — nothing to do."
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  [ "$NEED_OPENCODE" -eq 1 ] && echo "theme-sync: would set mode $CURRENT -> $WANT ($NAME, light window $LIGHT_START-$LIGHT_END)."
  # shellcheck disable=SC2034
  if [ "$TERM_NEED" -eq 1 ]; then echo "theme-sync: would set termux background $TERM_BG -> $TERM_WANT_BG, foreground $TERM_FG -> $TERM_WANT_FG."; fi
  # shellcheck disable=SC2034
  if [ "$PAL_NEED" -eq 1 ]; then echo "theme-sync: would set termux palette:$PAL_DRIFT (from $PAL_SRC)."; fi
  if [ "$NIGHT_NEED" -eq 1 ]; then echo "theme-sync: would set termux night-mode $PROP_NIGHT -> $TERM_WANT_NIGHT."; fi
  exit 2
fi

if [ "$NEED_OPENCODE" -eq 1 ]; then
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
fi

if [ "$PAL_NEED" -eq 1 ]; then
  apply_palette
fi

if [ "$TERM_NEED" -eq 1 ]; then
  apply_termux "$TERM_WANT_BG" "$TERM_WANT_FG"
fi

if [ "$NIGHT_NEED" -eq 1 ]; then
  apply_nightmode "$TERM_WANT_NIGHT"
fi

if [ "$TERM_NEED" -eq 1 ] || [ "$NIGHT_NEED" -eq 1 ] || [ "$PAL_NEED" -eq 1 ]; then
  if command -v termux-reload-settings >/dev/null 2>&1; then
    termux-reload-settings 2>/dev/null || true
  fi
  echo "theme-sync: note: night-mode needs force-stop + reopen to take effect."
fi

if [ "$NOTIFY" = "1" ] && command -v termux-notification >/dev/null 2>&1; then
  termux-notification --title "opencode theme" --content "Switched to $WANT ($NAME). Restart TUI + reopen Termux." 2>/dev/null || true
fi

echo "Restart the TUI to pick it up (cli.json is read at startup)."
