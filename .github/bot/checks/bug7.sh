#!/usr/bin/env bash
# Bug 7: some Bedrock mobile players cannot join or crash (D3, no fixers).
# Source after server.sh. A bot joins with Android client data (DeviceOS 1,
# pocket UI, touch input), sends touch player_auth_input and stays 30 s.
# This runs twice: Geyser defaults, then gameplay.enable-custom-content false.
# Each pass writes its own result line to the step summary. check_bug7
# returns 0 only when both passes are clean, 1 when either pass logs a
# server-side exception block or the server drops the spawned bot, and 3
# when a precondition does not hold (prints which one). The outcome stays
# unverified either way: client crashes cannot be observed from here.
# Uses $jar, $auth, $here and $ARTIFACTS from run.sh.

bug7_precondition() {
  echo "bug7: PRECONDITION not met: $*"
}

bug7_stop_bot() {
  local pid=$1 i
  for i in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# bug7_dump <out file>: runs "geyser dump offline" and writes the device
# platforms and the custom content setting Geyser reports to <out file>.
bug7_dump() {
  local out=$1 dump="$SERVER_DIR/plugins/Geyser-Spigot/dump.json" i
  rm -f "$dump"
  send 'geyser dump offline' || return 1
  for ((i = 0; i < 30; i++)); do
    if [ -s "$dump" ] && node -e '
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
      const found = []
      const walk = (o, p) => {
        if (!o || typeof o !== "object") return
        for (const [k, v] of Object.entries(o)) {
          if (/custom-?content/i.test(k)) found.push(`${p}${k}=${JSON.stringify(v)}`)
          walk(v, `${p}${k}.`)
        }
      }
      walk(d.config, "")
      console.log(`userPlatforms=${JSON.stringify(d.userPlatforms)}`)
      console.log(`config ${found.join(" ") || "(no custom content key)"}`)
    ' "$dump" > "$out" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "bug7: no readable dump.json after 30 s"
  return 1
}

# bug7_run <label> <enable-custom-content: true|false>: 0 clean, 1 fail, 3 precondition.
bug7_run() {
  local label=$1 custom=$2 work bot_pid bot_rc=0 name blocks why=''
  echo "bug7: === run $label (enable-custom-content $custom) ==="
  setup_server "$jar" "$auth" || { bug7_precondition "$label: server setup failed"; return 3; }
  if [ "$custom" = false ]; then
    printf 'gameplay:\n  enable-custom-content: false\n' \
      >> "$SERVER_DIR/plugins/Geyser-Spigot/config.yml" || return 3
  fi
  start_server || { bug7_precondition "$label: server start failed"; return 3; }
  wait_ready || { bug7_precondition "$label: server not ready"; return 3; }
  work="$SERVER_DIR/bug7"
  mkdir -p "$work" || return 3

  (cd "$here" && BOT_NAME=Bot7 STAY_SECS=30 exec node bug7.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  # Paper 26.3 logs the join message as "System chat: <name> joined the game".
  if ! wait_log "${LOG_PREFIX}(System chat: )?\.?Bot7 joined the game" 120; then
    bug7_stop_bot "$bot_pid"
    echo "bug7: $label bot log:"; cat "$work/bot.log"
    blocks=$(exception_blocks) || blocks=''
    if [ -n "$blocks" ]; then
      echo "bug7: $label FAIL mobile bot did not join; exception blocks in latest.log:"
      printf '%s\n' "$blocks"
      return 1
    fi
    bug7_precondition "$label: bot did not join"; return 3
  fi
  name=$(grep -m 1 -E "${LOG_PREFIX}(System chat: )?\.?Bot7 joined the game" "$LOG" \
    | sed -E "s|${LOG_PREFIX}(System chat: )?||; s| joined the game.*||") || name='?'
  echo "bug7: $label Paper name '$name'"

  # Evidence while the session is open: Geyser's own view of the device OS
  # (DumpInfo.userPlatforms) and of enable-custom-content (DumpInfo.config).
  sleep 5
  if bug7_dump "$work/dump.txt"; then
    sed "s/^/bug7: $label dump /" "$work/dump.txt"
  else
    why+=" geyser dump failed;"
  fi

  wait "$bot_pid" || bot_rc=$?
  sleep 2
  echo "bug7: $label bot log:"; cat "$work/bot.log"

  mkdir -p "$ARTIFACTS/bug7-$label" || true
  cp "$work/bot.log" "$ARTIFACTS/bug7-$label/" 2>/dev/null || true
  cp "$work/dump.txt" "$ARTIFACTS/bug7-$label/" 2>/dev/null || true

  blocks=$(exception_blocks) || { bug7_precondition "$label: latest.log missing"; return 3; }
  if [ -n "$blocks" ]; then
    echo "bug7: $label FAIL exception blocks in latest.log:"
    printf '%s\n' "$blocks"
    return 1
  fi

  grep -q 'client data DeviceOS=1 UIProfile=1 CurrentInputMode=2 DefaultInputMode=2' "$work/bot.log" \
    || why+=" bot client data is not Android/pocket/touch;"
  grep -q ': spawned at' "$work/bot.log" || why+=" bot did not spawn;"
  grep -qE 'userPlatforms=.*"(GOOGLE|Android)":[1-9]' "$work/dump.txt" 2>/dev/null \
    || why+=" Geyser did not report an Android session;"
  grep -qiE "custom-?content=$custom( |\$)" "$work/dump.txt" 2>/dev/null \
    || why+=" Geyser config does not show enable-custom-content=$custom;"

  if [ "$bot_rc" -ne 0 ] && grep -q ': spawned at' "$work/bot.log"; then
    echo "bug7: $label FAIL the spawned mobile bot did not stay 30 s (see bot log)"
    return 1
  fi
  if [ -n "$why" ]; then bug7_precondition "$label:$why"; return 3; fi
  [ "$bot_rc" -eq 0 ] || { bug7_precondition "$label: bot exited $bot_rc"; return 3; }
  echo "bug7: $label clean: Android bot stayed 30 s, no exception blocks"
  return 0
}

bug7_save_first_run() {
  local dir="$ARTIFACTS/bug7-$1" f
  mkdir -p "$dir" || return 0
  for f in logs/latest.log console.out plugins/Geyser-Spigot/config.yml; do
    cp "$SERVER_DIR/$f" "$dir/" 2>/dev/null || true
  done
}

bug7_word() {
  case $1 in 0) echo PASS ;; 1) echo FAIL ;; *) echo PRECONDITION ;; esac
}

check_bug7() {
  local rc_on=0 rc_off=0 summary=${GITHUB_STEP_SUMMARY:-/dev/null}
  bug7_run custom-content-on true || rc_on=$?
  echo "check=bug7 pass=1 enable-custom-content=true result=$(bug7_word "$rc_on")" | tee -a "$summary"
  stop_server
  bug7_save_first_run custom-content-on
  # setup_server deletes the server dir and writes a fresh config.yml;
  # bug7_run then appends gameplay.enable-custom-content: false.
  bug7_run custom-content-off false || rc_off=$?
  echo "check=bug7 pass=2 enable-custom-content=false result=$(bug7_word "$rc_off")" | tee -a "$summary"
  # The EXIT trap in run.sh saves the second pass's logs under $ARTIFACTS/$auth.
  cp "$SERVER_DIR/plugins/Geyser-Spigot/config.yml" "$ARTIFACTS/bug7-custom-content-off/" 2>/dev/null || true
  local server_side='see pass results'
  if [ "$rc_on" -eq 0 ] && [ "$rc_off" -eq 0 ]; then server_side='not reproduced on preview'; fi
  echo "check=bug7 outcome=unverified (client crashes cannot be observed; server side: $server_side)" \
    | tee -a "$summary"
  if [ "$rc_on" -eq 1 ] || [ "$rc_off" -eq 1 ]; then return 1; fi
  if [ "$rc_on" -ne 0 ] || [ "$rc_off" -ne 0 ]; then return 3; fi
  return 0
}
