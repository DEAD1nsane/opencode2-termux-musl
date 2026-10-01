#!/data/data/com.termux/files/usr/bin/sh
# Watchdog for opencode's local HTTPS proxy (proxy.py) on Termux.
#
# Why this exists: every outbound HTTPS request from opencode (model API,
# MCP remote servers like railway, models.dev) must pass through proxy.py
# on 127.0.0.1:8080, because Bun/musl networking cannot resolve DNS on
# Android. When proxy.py dies, remote MCP servers fail instantly with
# "Unable to connect. Is the computer able to access the url?" and any
# directory that boots while the proxy is down caches that failure.
#
# cron, runit and termux-boot are not available on this device, so the
# opencode wrapper starts this script on every launch; flock keeps it
# single-instance, so repeated launches are harmless.
#
# Env:
#   WATCHDOG_INTERVAL  seconds between checks (default 60)
#   PROXY_DEBUG is always exported here so proxy.py logs to
#   $TMPDIR/proxy.log instead of discarding stderr.

LOCK="${TMPDIR:-$HOME/tmp}/opencode-proxy-watchdog.lock"
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
flock -n 9 || exit 0

PROXY_PY="/data/data/com.termux/files/usr/libexec/opencode/proxy.py"
PORT=8080
INTERVAL="${WATCHDOG_INTERVAL:-60}"
PLOG="${TMPDIR:-$HOME/tmp}/proxy.log"
WLOG="${TMPDIR:-$HOME/tmp}/proxy-watchdog.log"

export PROXY_DEBUG=1

port_open() {
  python3 -c "import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect(('127.0.0.1', ${PORT}))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()" 2>/dev/null
}

start_proxy() {
  # -fx: exact full-cmdline match so we only ever kill the real proxy.py,
  # never a shell whose command line merely mentions the string.
  pkill -fx "python3 ${PROXY_PY}" 2>/dev/null
  sleep 0.3
  # 9>&- : close the watchdog's lock fd in the child. Without this the
  # spawned proxy inherits fd 9, and because flock only releases when every
  # reference to the open file description exits, a killed watchdog would
  # leave the lock held inside the long-lived proxy — deadlocking every
  # future watchdog against its own lock.
  PROXY_DEBUG=1 nohup python3 "${PROXY_PY}" >/dev/null 2>&1 9>&- &
  sleep 0.7
}

# Keep debug logs bounded. proxy.py opens proxy.log in append mode
# (O_APPEND), so truncating in place is safe — new writes land at EOF=0.
rotate() {
  [ -f "$1" ] || return 0
  [ "$(wc -c < "$1")" -gt 1048576 ] || return 0
  cp "$1" "$1.old" 2>/dev/null
  : > "$1"
}

log() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$WLOG"
}

log "watchdog started pid=$$ interval=${INTERVAL}s"
while :; do
  if port_open; then
    :
  else
    log "port ${PORT} closed — restarting proxy.py"
    start_proxy
    if port_open; then
      log "proxy.py restarted OK"
    else
      log "proxy.py restart FAILED"
    fi
  fi
  rotate "${PLOG}"
  rotate "${WLOG}"
  sleep "${INTERVAL}"
done
