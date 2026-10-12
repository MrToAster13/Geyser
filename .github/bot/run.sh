#!/usr/bin/env bash
# Usage: run.sh <check> <geyser jar>
# Checks: join (first milestone: one bot joins and stays 30 s).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check=$1
jar=$(realpath "$2")
source "$here/server.sh"

auth=floodgate
result=1

run_join() {
  setup_server "$jar" "$auth" || return 1
  start_server || return 1
  wait_ready || return 1
  # Return 2 only when the bot fails, so only that triggers the D1 fallback.
  (cd "$here" && BOT_NAME=Bot1 STAY_SECS=30 node join.js) || return 2
  # The join line gives the exact name Paper uses (D1, R4-f).
  grep -E "$LOG_PREFIX.*joined the game" "$LOG" || { echo "no join line" >&2; return 1; }
  local blocks
  blocks=$(exception_blocks) || return 1
  if [ -n "$blocks" ]; then
    echo "exception blocks in latest.log:"; printf '%s\n' "$blocks"
    return 1
  fi
}

ARTIFACTS=${ARTIFACTS:-$PWD/bot-logs}
save_logs() {
  mkdir -p "$ARTIFACTS/$auth"
  local f
  for f in logs/latest.log console.out server.properties whitelist.json; do
    cp "$SERVER_DIR/$f" "$ARTIFACTS/$auth/" 2>/dev/null || true
  done
}
trap 'stop_server; save_logs' EXIT

case $check in
  join)
    rc=0
    run_join || rc=$?
    if [ "$rc" -eq 0 ]; then
      result=0
    elif [ "$rc" -eq 2 ]; then
      # D1 fallback: the bot failed under floodgate auth. Retry once under
      # offline auth and record the mode. Server, log and exception failures
      # do not fall back, and neither does a bot failure with exceptions in
      # the floodgate log.
      fb_blocks=$(exception_blocks) || fb_blocks='(latest.log missing)'
      if [ -n "$fb_blocks" ]; then
        echo "bot failed under floodgate with exception blocks, no fallback:"
        printf '%s\n' "$fb_blocks"
      else
        echo "bot failed under floodgate, retrying with auth-type offline"
        stop_server; save_logs; auth=offline
        run_join && result=0
      fi
    fi
    ;;
  bug3) source "$here/checks/bug3.sh"; rc=0; check_bug3 || rc=$?; [ "$rc" -eq 0 ] && result=0 ;;
  *) echo "unknown check $check" >&2; exit 2 ;;
esac

echo "check=$check auth=$auth result=$([ $result -eq 0 ] && echo PASS || echo FAIL)" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit $result
