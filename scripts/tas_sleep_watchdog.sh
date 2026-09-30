#!/usr/bin/env bash
# Anti-stuck watchdog for the TAS loop.
#
# Failure mode it guards: the agent misreads a per-turn budget cutoff as a dead scorer
# and issues `sleep <huge> && rescore`, so opencode blocks on that child and the turn
# hangs forever (TURN_TIMEOUT=0 = no recovery). This watchdog SIGKILLs any `sleep`
# process whose duration exceeds MAX_SLEEP. It never touches opencode itself, so the
# `-c` session is preserved (unlike TURN_TIMEOUT SIGTERM-ing opencode, which corrupted
# it). When the sleep dies, opencode's tool call returns and the agent proceeds.
#
# Sourceable for testing: `WATCHDOG_SOURCE=1 . tas_sleep_watchdog.sh` exposes
# to_seconds() and scan_once() without starting the loop.

MAX_SLEEP="${WATCHDOG_MAX_SLEEP:-900}"   # kill sleeps longer than this many seconds (15 min)
INTERVAL="${WATCHDOG_INTERVAL:-30}"      # scan cadence

# Convert a `sleep` duration arg (e.g. 21600, 6h, 10m, 30s, 1d) to whole seconds.
# Echoes the integer, or nothing if unparseable.
to_seconds() {
  local a="$1" n unit
  case "$a" in
    ''|*[!0-9smhd.]*) return 0 ;;            # reject anything unexpected
  esac
  n="${a%[smhd]}"; unit="${a#"$n"}"
  case "$n" in ''|*[!0-9.]*) return 0 ;; esac
  # drop any fractional part (sleep allows floats; whole seconds are enough here)
  n="${n%.*}"; [ -n "$n" ] || n=0
  case "$unit" in
    s|'') echo "$n" ;;
    m)    echo $(( n * 60 )) ;;
    h)    echo $(( n * 3600 )) ;;
    d)    echo $(( n * 86400 )) ;;
  esac
}

# One scan pass: kill every `sleep` proc whose duration > MAX_SLEEP. Echoes killed pids.
scan_once() {
  local p pid comm arg secs
  for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    comm=$(cat "$p/comm" 2>/dev/null) || continue
    [ "$comm" = "sleep" ] || continue
    arg=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | awk '{print $2}')
    secs=$(to_seconds "$arg")
    if [ -n "$secs" ] && [ "$secs" -gt "$MAX_SLEEP" ] 2>/dev/null; then
      pid="${p#/proc/}"
      kill -9 "$pid" 2>/dev/null && echo "$pid"
    fi
  done
}

# When sourced for tests, stop here.
[ "${WATCHDOG_SOURCE:-0}" = "1" ] && return 0

echo "tas_sleep_watchdog: MAX_SLEEP=${MAX_SLEEP}s INTERVAL=${INTERVAL}s (pid $$)"
while true; do
  for k in $(scan_once); do
    echo "tas_sleep_watchdog: KILLED runaway sleep pid=$k (> ${MAX_SLEEP}s)"
  done
  sleep "$INTERVAL"
done
