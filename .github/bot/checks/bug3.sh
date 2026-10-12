#!/usr/bin/env bash
# Bug 3: Bedrock players get kicked out of beds. Java 26.3 teleports a player
# to the bed head when they start sleeping; Geyser used to pass that teleport
# on, and the Bedrock client wakes up when teleported (fixed upstream in
# "Fix: clients being kicked out of beds because of a teleport packet").
# Source after server.sh. check_bug3 returns 0 PASS (the bot entered the bed,
# got no teleport and the bed is still occupied after the hold),
# 1 FAIL (all preconditions held and the bot got a teleport or left the bed),
# 3 precondition not met (prints which one).
# Uses $jar, $auth and $here from run.sh.

BUG3_LINE=''
BUG3_HOLD=${BUG3_HOLD:-20}
# Command errors that end a wait early; the caller reads BUG3_LINE.
BUG3_ERR='Unknown or incomplete command|Incorrect argument|<--\[HERE\]'

# bug3_cmd <command> <ERE> [timeout s]: sends a console command and waits for
# the ERE, anywhere after the latest.log prefix (and "System chat: "), in
# lines written after the send, or for a command error. The matched line goes
# to BUG3_LINE. Earlier lines never match, so repeated results are read per
# command.
bug3_cmd() {
  local n i re="${LOG_PREFIX}(System chat: )?.*($2)|$BUG3_ERR"
  n=$(wc -l < "$LOG") || return 1
  send "$1" || return 1
  for ((i = 0; i < ${3:-10}; i++)); do
    BUG3_LINE=$(tail -n +"$((n + 1))" "$LOG" | grep -E "$re" | head -n 1 || true)
    if [ -n "$BUG3_LINE" ]; then
      echo "bug3: $1 -> ${BUG3_LINE#*]: }"
      if grep -qE "$BUG3_ERR" <<< "$BUG3_LINE"; then return 1; fi
      return 0
    fi
    sleep 1
  done
  echo "bug3: timeout waiting for '$2' after: $1"
  return 1
}

# bug3_test <execute condition>: 0 when "Test passed", 1 when "Test failed",
# 2 when no result line appears.
bug3_test() {
  bug3_cmd "execute $1" 'Test (passed|failed)' 10 || return 2
  case $BUG3_LINE in *'Test passed'*) return 0 ;; *) return 1 ;; esac
}

# bug3_wait_file <path> <timeout s> <bot pid>
bug3_wait_file() {
  local i
  for ((i = 0; i < $2; i++)); do
    if [ -f "$1" ]; then return 0; fi
    kill -0 "$3" 2>/dev/null || { echo "bug3: bot exited before $(basename "$1")"; return 1; }
    sleep 1
  done
  echo "bug3: timeout waiting for $(basename "$1")"
  return 1
}

bug3_precondition() {
  echo "bug3: PRECONDITION not met: $*"
  echo "check=bug3 outcome=PRECONDITION" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# bug3_stop_bot <pid>: waits up to 20 s for the bot to exit, then kills it.
# Sets BUG3_BOT_RC to the bot's exit code.
BUG3_BOT_RC=''
bug3_stop_bot() {
  local pid=$1 i
  for i in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  BUG3_BOT_RC=0
  wait "$pid" 2>/dev/null || BUG3_BOT_RC=$?
}

# bug3_night: 0 when the day time is in the sleepable night window.
bug3_night() {
  local t
  bug3_cmd 'time query daytime' 'The time is [0-9]+' 10 || return 1
  t=$(grep -oE 'The time is [0-9]+' <<< "$BUG3_LINE" | grep -oE '[0-9]+$')
  [ -n "$t" ] && [ "$t" -ge 13000 ] && [ "$t" -lt 23000 ]
}

check_bug3() {
  local work bot_pid name px py pz fx fy fz hx why='' rc
  work="$SERVER_DIR/bug3"
  setup_server "$jar" "$auth" || { bug3_precondition "server setup failed"; return 3; }
  # Geyser debug output shows "Teleport (...)" and the skipped bed teleport.
  echo 'debug-mode: true' >> "$SERVER_DIR/plugins/Geyser-Spigot/config.yml" || return 3
  start_server || { bug3_precondition "server start failed"; return 3; }
  wait_ready || { bug3_precondition "server not ready"; return 3; }
  mkdir -p "$work" || return 3

  (cd "$here" && BOT_NAME=Bot1 BUG3_DIR="$work" exec node bug3.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  if ! wait_log "${LOG_PREFIX}\.?Bot1 joined the game" 120; then
    cat "$work/bot.log"; bug3_stop_bot "$bot_pid"
    bug3_precondition "bot did not join"; return 3
  fi
  # The join line gives the exact name Paper uses (Floodgate adds a prefix).
  name=$(grep -E "${LOG_PREFIX}\.?Bot1 joined the game" "$LOG" | head -n 1 \
    | sed -E "s/${LOG_PREFIX}//; s/ joined the game.*//")
  echo "bug3: Paper name '$name'"

  if ! bug3_wait_file "$work/pos" 30 "$bot_pid"; then
    cat "$work/bot.log"; bug3_stop_bot "$bot_pid"
    bug3_precondition "bot reported no position"; return 3
  fi
  read -r px py pz < "$work/pos"
  read -r fx fy fz < <(awk -v x="$px" -v y="$py" -v z="$pz" '
    function fl(v) { return (v < int(v)) ? int(v) - 1 : int(v) }
    BEGIN { printf "%d %d %d\n", fl(x) + 1, fl(y + 0.001), fl(z) }')
  hx=$((fx + 1))
  echo "bug3: bot feet $px $py $pz; bed foot $fx $fy $fz, head $hx $fy $fz (facing east)"

  # Setup. Peaceful: no "monsters nearby" refusal. The sleep percentage over
  # 100 keeps one sleeper from skipping the night and waking everyone, which
  # would end the hold for a reason unrelated to the bug. Rule name changed in
  # 1.21.11, so the old name is the fallback.
  bug3_cmd 'difficulty peaceful' 'difficulty (has been set|did not change)' || why+=" difficulty;"
  if ! bug3_cmd 'gamerule players_sleeping_percentage 101' 'is now set to: 101'; then
    bug3_cmd 'gamerule playersSleepingPercentage 101' 'is now set to: 101' || why+=" sleep percentage gamerule;"
  fi
  bug3_cmd 'time set 18000' 'Set the time to 18000' || why+=" time set;"
  bug3_cmd 'scoreboard objectives add bug3slept minecraft.custom:minecraft.sleep_in_bed' \
    'Created new objective' || why+=" sleep_in_bed objective;"
  bug3_cmd "setblock $fx $fy $fz minecraft:red_bed[facing=east,part=foot]" 'Changed the block|Could not set' || why+=" setblock foot;"
  bug3_cmd "setblock $hx $fy $fz minecraft:red_bed[facing=east,part=head]" 'Changed the block|Could not set' || why+=" setblock head;"
  if [ -n "$why" ]; then
    bug3_stop_bot "$bot_pid"; bug3_precondition "setup commands failed:$why"; return 3
  fi

  # Preconditions before the click (R2-e): bed placed, night, nothing slept yet.
  bug3_test "if block $fx $fy $fz minecraft:red_bed[part=foot,facing=east,occupied=false]" || why+=" bed foot missing;"
  bug3_test "if block $hx $fy $fz minecraft:red_bed[part=head,facing=east,occupied=false]" || why+=" bed head missing;"
  bug3_test "if block $fx $((fy + 1)) $fz minecraft:air" || why+=" block above bed foot not air;"
  bug3_night || why+=" not night;"
  bug3_test "as $name if entity @s[gamemode=!spectator]" || why+=" bot is spectator or not found;"
  if [ -n "$why" ]; then
    bug3_stop_bot "$bot_pid"; bug3_precondition "$why"; return 3
  fi

  echo "$fx $fy $fz" > "$work/go" || return 3
  if ! bug3_wait_file "$work/used" 30 "$bot_pid"; then
    bug3_stop_bot "$bot_pid"; cat "$work/bot.log"
    bug3_precondition "bot did not send the bed click (see bot log)"; return 3
  fi
  sleep 3

  # Precondition: the server put the player to sleep. The stat counts even if
  # the player was woken a tick later, so it proves entry on either outcome.
  if ! bug3_cmd "scoreboard players get $name bug3slept" 'has [0-9]+ \[bug3slept\]|none is set|Can.t get value'; then
    why+=" no sleep_in_bed score result;"
  elif ! grep -qE 'has [1-9][0-9]* \[bug3slept\]' <<< "$BUG3_LINE"; then
    why+=" bot never entered the bed (sleep_in_bed not counted);"
  fi
  if [ -n "$why" ]; then
    bug3_stop_bot "$bot_pid"; echo "bug3: bot log:"; cat "$work/bot.log"
    bug3_precondition "$why"; return 3
  fi
  echo "bug3: the server counted sleep_in_bed for $name; holding ${BUG3_HOLD} s"
  sleep "$BUG3_HOLD"

  # Signal: the bed head is still occupied after the hold.
  local occupied=0
  bug3_test "if block $hx $fy $fz minecraft:red_bed[part=head,occupied=true]" || occupied=$?
  # The hold must have stayed in the night (R2-e), or a wake proves nothing.
  bug3_night || why+=" night ended during the hold;"
  touch "$work/stop" || return 3
  bug3_stop_bot "$bot_pid"
  echo "bug3: bot log (exit $BUG3_BOT_RC):"; cat "$work/bot.log"

  echo "bug3: Geyser debug lines about teleports:"
  grep -E 'Teleport \(|pending bed interaction|^to \(|\]: to \(' "$LOG" | tail -n 20 || true
  local blocks
  blocks=$(exception_blocks) || true
  if [ -n "$blocks" ]; then
    echo "bug3: exception blocks in latest.log (diagnostic):"; printf '%s\n' "$blocks"
  fi

  [ "$occupied" -eq 2 ] && why+=" no result for the occupied test;"
  [ "$BUG3_BOT_RC" = 3 ] && why+=" bot-side precondition failed (see bot log);"
  local result teleports
  result=$(grep -E 'RESULT teleports_after_click=' "$work/bot.log" | tail -n 1 || true)
  [ -n "$result" ] || why+=" bot printed no RESULT line (exit $BUG3_BOT_RC);"
  if [ -n "$why" ]; then bug3_precondition "$why"; return 3; fi

  teleports=$(grep -oE 'teleports_after_click=[0-9]+' <<< "$result" | cut -d= -f2)
  rc=0
  [ "$teleports" -gt 0 ] && rc=1
  [ "$occupied" -ne 0 ] && rc=1
  if [ "$rc" -eq 0 ]; then
    echo "bug3: PASS $name stayed in the bed at $hx $fy $fz for ${BUG3_HOLD} s, no teleport after the click"
  else
    echo "bug3: FAIL $name was kicked out of the bed: teleports_after_click=$teleports, head occupied after ${BUG3_HOLD} s: $([ "$occupied" -eq 0 ] && echo yes || echo no)"
  fi
  return "$rc"
}
