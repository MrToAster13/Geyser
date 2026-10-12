#!/usr/bin/env bash
# Bug 4: mobs move in jerks on Bedrock. Paper 26.3 sends stepped move
# packets and Geyser forwards only part of each one.
# Source after server.sh. check_bug4 returns 0 PASS (the position Geyser gave
# the Bedrock client matched the server's within the limit), 1 FAIL (all
# preconditions held and it did not), 3 precondition not met (prints which).
# Uses $jar, $auth and $here from run.sh.

BUG4_LINE=''
BUG4_POS=''

# bug4_cmd <command> <ERE> [timeout s]: sends a console command and waits for
# the ERE (case-insensitive) in latest.log lines written after the send. The
# matched line goes to BUG4_LINE.
bug4_cmd() {
  local n i
  n=$(wc -l < "$LOG") || return 1
  send "$1" || return 1
  # Poll every 0.2 s: the slide must finish within the server's 400-tick
  # sync timer, so command round trips stay short.
  for ((i = 0; i < ${3:-10} * 5; i++)); do
    BUG4_LINE=$(tail -n +"$((n + 1))" "$LOG" | grep -iE "$2" | head -n 1 || true)
    if [ -n "$BUG4_LINE" ]; then return 0; fi
    sleep 0.2
  done
  echo "bug4: timeout waiting for '$2' after: $1"
  return 1
}

# bug4_pos: server position of the tagged pig into BUG4_POS as "x y z".
bug4_pos() {
  BUG4_POS=''
  bug4_cmd "data get entity @e[tag=bug4,limit=1] Pos" \
    'entity data|No entity was found|Found no elements|<--\[HERE\]' 10 || return 1
  # The last [...] on the line is the Pos list, like [3.5d, -60.0d, 0.5d].
  BUG4_POS=$(printf '%s\n' "$BUG4_LINE" | grep -oE '\[[^][]*[0-9][dD]\]' | tail -n 1 \
    | sed -E 's/[][dD]//g; s/,/ /g' | awk 'NF == 3 { print $1 + 0, $2 + 0, $3 + 0 }')
  [ -n "$BUG4_POS" ] || { echo "bug4: could not parse: $BUG4_LINE"; return 1; }
  return 0
}

# bug4_put <file> <text>: hands a file to the bot and waits for <file>_ok.
bug4_put() {
  printf '%s\n' "$2" > "$work/.$1" && mv "$work/.$1" "$work/$1" || return 1
  bug4_wait_file "$work/$1_ok" 30 "$bot_pid"
}

# bug4_wait_file <path> <timeout s> <bot pid>
bug4_wait_file() {
  local i
  for ((i = 0; i < $2 * 5; i++)); do
    if [ -f "$1" ]; then return 0; fi
    kill -0 "$3" 2>/dev/null || { echo "bug4: bot exited before $(basename "$1")"; return 1; }
    sleep 0.2
  done
  echo "bug4: timeout waiting for $(basename "$1")"
  return 1
}

bug4_precondition() {
  echo "bug4: PRECONDITION not met: $*"
  echo "check=bug4 outcome=PRECONDITION" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

bug4_stop_bot() {
  local pid=$1 i
  for i in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# bug4_abort <reason>: stops the bot, prints its log, reports PRECONDITION.
bug4_abort() {
  bug4_stop_bot "$bot_pid"; echo "bug4: bot log:"; cat "$work/bot.log"
  bug4_precondition "$*"
}

check_bug4() {
  local work bot_pid name bx by bz sx sy sz before after base bres rc
  work="$SERVER_DIR/bug4"
  setup_server "$jar" "$auth" || { bug4_precondition "server setup failed"; return 3; }
  start_server || { bug4_precondition "server start failed"; return 3; }
  wait_ready || { bug4_precondition "server not ready"; return 3; }
  mkdir -p "$work" || return 3

  (cd "$here" && BOT_NAME=Bot1 BUG4_DIR="$work" exec node bug4.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  if ! wait_log "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" 120; then
    bug4_abort "bot did not join"; return 3
  fi
  name=$(grep -E "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" "$LOG" | head -n 1 \
    | sed -E "s|${LOG_PREFIX}(System chat: )?||; s| joined the game.*||")
  echo "bug4: Paper name '$name'"

  if ! bug4_wait_file "$work/pos" 30 "$bot_pid"; then
    bug4_abort "bot sent no position"; return 3
  fi
  read -r bx by bz < "$work/pos"
  # Pig on the ground 3 blocks east of the bot; it slides east, away from it.
  sx=$(awk -v v="$bx" 'BEGIN { printf "%.1f", v + 3.5 }')
  sz=$(awk -v v="$bz" 'BEGIN { printf "%.1f", v + 0.5 }')
  sy=$by
  echo "bug4: bot block $bx $by $bz, pig spot $sx $sy $sz"

  # Only our pig near the bot. Speed 0 stops wandering but keeps physics
  # (NoAI would stop gravity and Motion too). Resistance 5 and a large safe
  # fall distance keep the pig alive after the fall.
  bug4_cmd "kill @e[type=minecraft:pig]" 'Killed|No entity was found|<--\[HERE\]' || true
  if ! bug4_put spawn "$sx $sy $sz"; then bug4_abort "bot did not read the spawn spot"; return 3; fi
  if ! bug4_cmd "summon minecraft:pig $sx $sy $sz {Tags:[\"bug4\"],PersistenceRequired:1b}" \
      'Summoned new|Unable to summon|<--\[HERE\]' \
     || [[ $BUG4_LINE != *'ummoned new'* ]]; then
    echo "bug4: summon -> ${BUG4_LINE#*]: }"; bug4_abort "summon failed"; return 3
  fi
  echo "bug4: summon -> ${BUG4_LINE#*]: }"
  if ! bug4_cmd "attribute @e[tag=bug4,limit=1] minecraft:movement_speed base set 0" \
      'Base value for attribute|not a valid entity|has no attribute|No entity was found|Unknown|<--\[HERE\]' \
     || [[ $BUG4_LINE != *'ase value for attribute'* ]]; then
    bug4_abort "could not set movement_speed 0: ${BUG4_LINE#*]: }"; return 3
  fi
  bug4_cmd "effect give @e[tag=bug4,limit=1] minecraft:resistance 300 4 true" \
    'Applied effect|Unable|No entity|<--\[HERE\]' && echo "bug4: effect -> ${BUG4_LINE#*]: }"
  bug4_cmd "attribute @e[tag=bug4,limit=1] minecraft:safe_fall_distance base set 1000" \
    'Base value for attribute|has no attribute|Unknown|No entity|<--\[HERE\]' && echo "bug4: attribute -> ${BUG4_LINE#*]: }"

  if ! bug4_wait_file "$work/pig" 20 "$bot_pid"; then
    bug4_abort "bot got no add_entity for the pig"; return 3
  fi
  echo "bug4: bot saw add_entity: $(cat "$work/pig")"

  # Teleport in place so the 400-tick sync timer starts now, then baseline.
  bug4_cmd "tp @e[tag=bug4,limit=1] $sx $sy $sz" 'Teleported|No entity|<--\[HERE\]' || true
  sleep 1.5
  if ! bug4_pos; then bug4_abort "no server position at rest"; return 3; fi
  base=$BUG4_POS
  echo "bug4: server Pos at rest $base"
  if ! bug4_put base "$base"; then bug4_abort "bot did not take the baseline"; return 3; fi

  # Slide east along the ground.
  if ! bug4_put slide go; then bug4_abort "bot did not start the slide phase"; return 3; fi
  if ! bug4_cmd "data merge entity @e[tag=bug4,limit=1] {Motion:[1.5d,0.0d,0.0d]}" \
      'System chat: |<--\[HERE\]' 10; then
    bug4_abort "Motion was not applied"; return 3
  fi
  echo "bug4: motion -> ${BUG4_LINE#*]: }"
  sleep 3
  if ! bug4_pos; then bug4_abort "no server position after the slide"; return 3; fi
  after=$BUG4_POS
  echo "bug4: server Pos after slide $after"
  # Server-side precondition (R2-e): the pig really moved.
  if ! awk -v a="$base" -v b="$after" 'BEGIN { split(a, p); split(b, q);
      d = sqrt((q[1]-p[1])^2 + (q[3]-p[3])^2); printf "bug4: server slide distance %.3f\n", d; exit !(d >= 1) }'; then
    bug4_abort "pig did not slide on the server"; return 3
  fi
  if ! bug4_put probe_slide "$after"; then bug4_abort "bot did not read the slide probe"; return 3; fi

  # Fall 30 blocks from above the spawn spot.
  before="$sx $((sy + 30)) $sz"
  if ! bug4_put tp "$before"; then bug4_abort "bot did not start the fall phase"; return 3; fi
  if ! bug4_cmd "tp @e[tag=bug4,limit=1] $before" 'Teleported|No entity|<--\[HERE\]' \
     || [[ $BUG4_LINE != *'eleported'* ]]; then
    bug4_abort "tp up failed"; return 3
  fi
  echo "bug4: tp -> ${BUG4_LINE#*]: }"
  sleep 5
  if ! bug4_pos; then bug4_abort "no server position after the fall"; return 3; fi
  after=$BUG4_POS
  echo "bug4: server Pos after fall $after"
  if ! awk -v b="$after" -v y="$sy" 'BEGIN { split(b, q); exit !(q[2] < y + 2) }'; then
    bug4_abort "pig did not land after the fall"; return 3
  fi
  if ! bug4_put probe_fall "$after"; then bug4_abort "bot did not read the fall probe"; return 3; fi

  bug4_put end go || true
  bug4_stop_bot "$bot_pid"
  echo "bug4: bot log:"; cat "$work/bot.log"
  local blocks
  blocks=$(exception_blocks) || true
  if [ -n "$blocks" ]; then
    echo "bug4: exception blocks in latest.log (diagnostic):"; printf '%s\n' "$blocks"
  fi

  bres=$(cat "$work/result" 2>/dev/null || true)
  echo "bug4: bot result: ${bres:-none}"
  case $bres in
    PASS*) rc=0; echo "bug4: PASS Bedrock pig position matched the server: ${bres#PASS }" ;;
    FAIL*) rc=1; echo "bug4: FAIL Bedrock pig position left the server's by more than the limit: ${bres#FAIL }" ;;
    *) rc=3; bug4_precondition "bot gave no result (${bres:-none})" ;;
  esac
  return "$rc"
}
