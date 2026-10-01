#!/bin/sh
# enable-formatter.sh — make opencode's prettier formatter work on Termux.
#
# The bug: opencode's built-in prettier formatter spawns the npm-cached
# `.bin/prettier`, whose `#!/usr/bin/env node` shebang cannot resolve under
# the musl wrapper (the wrapper swaps LD_PRELOAD to libresolvefix.so, so
# termux-exec's shebang rewrite never applies, and /usr/bin/env does not
# exist on Android). Every format attempt fails with "NotFound:
# ChildProcess.spawn" and is silently skipped.
#
# The fix: install prettier globally via Termux npm and override the
# built-in formatter command to invoke it through node directly
# (`node /path/to/prettier.cjs --write $FILE`) — no shebang involved.
#
# Usage:
#   sh scripts/enable-formatter.sh
#
# Requires: node, npm, python3. Only the "formatter" key of
# ~/.config/opencode/opencode.json is modified (with a .bak backup).

set -e

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
[ -d "$CFG_DIR" ] || { echo "error: $CFG_DIR not found — is opencode installed?" >&2; exit 1; }

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v node   >/dev/null 2>&1 || die "node not found (pkg install nodejs)"
command -v npm    >/dev/null 2>&1 || die "npm not found (pkg install nodejs)"
command -v python3 >/dev/null 2>&1 || die "python3 not found (pkg install python)"

log "Installing prettier globally via npm..."
npm install -g prettier >/dev/null 2>&1 || die "npm install -g prettier failed"

NPM_ROOT="$(npm root -g 2>/dev/null)"
PRETTIER_CJS="$NPM_ROOT/prettier/bin/prettier.cjs"
[ -f "$PRETTIER_CJS" ] || die "Could not find prettier.cjs under $NPM_ROOT/prettier"

log "Verifying prettier runs via node..."
node "$PRETTIER_CJS" --version >/dev/null 2>&1 || die "node $PRETTIER_CJS --version failed"
log "prettier $(node "$PRETTIER_CJS" --version 2>/dev/null) at $PRETTIER_CJS"

CONFIG=""
for candidate in "$CFG_DIR/opencode.json" "$CFG_DIR/opencode.jsonc"; do
  [ -f "$candidate" ] && CONFIG="$candidate" && break
done
[ -n "$CONFIG" ] || die "No opencode.json(c) in $CFG_DIR — create one with { \"\\$schema\": \"https://opencode.ai/config.json\" }"

case "$CONFIG" in
  *.jsonc)
    cat <<EOF
warn: $CONFIG is JSONC (may contain comments); automatic merge is unsafe.
Add this to it by hand instead:
  "formatter": {
    "prettier": {
      "command": ["node", "$PRETTIER_CJS", "--write", "\$FILE"]
    }
  },
EOF
    exit 1
    ;;
esac

cp "$CONFIG" "$CONFIG.bak"
log "Backed up $CONFIG -> $CONFIG.bak"

python3 - "$CONFIG" "$PRETTIER_CJS" <<'PY'
import json, sys
path, prettier = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["formatter"] = {"prettier": {"command": ["node", prettier, "--write", "$FILE"]}}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"formatter override written to {path}")
PY

log "Done. Restart opencode (or the shared service) to pick up the config."
