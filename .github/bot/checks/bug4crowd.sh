#!/usr/bin/env bash
# Bug 4, crowd variant: about 90 named mobs walk under their own AI near a
# creative bot for 60 s. Then the server freezes and the check compares the
# position Geyser gave the Bedrock client for every mob with the server's.
# Source after server.sh. check_bug4crowd returns 0 PASS, 1 FAIL (some mob
# is off by more than the limit), 3 precondition not met (prints which).
# Uses $jar, $auth and $here from run.sh, and the helpers in bug4.sh.
source "$here/checks/bug4.sh"

BUG4C_WANDER_SECS=${BUG4C_WANDER_SECS:-60}

bug4c_precondition() {
  echo "bug4crowd: PRECONDITION not met: $*"
  echo "check=bug4crowd outcome=PRECONDITION" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

bug4c_abort() {
  bug4_stop_bot "$bot_pid"; echo "bug4crowd: bot log:"; cat "$work/bot.log"
  bug4c_precondition "$*"
}

# Mob types and counts. Horses and rabbits are the fast ones, and every third
# mob also gets movement_speed 0.4. Wolves chase sheep and rabbits, zombies
# chase villagers; Resistance V keeps every one of them alive.
BUG4C_MOBS='cow 12 sheep 12 pig 12 chicken 12 horse 8 villager 8 zombie 8 spider 6 rabbit 8 wolf 6'

check_bug4crowd() {
  local work bot_pid name bx by bz count n i lines got last rc bres
  work="$SERVER_DIR/bug4crowd"
  setup_server "$jar" "$auth" || { bug4c_precondition "server setup failed"; return 3; }
  start_server || { bug4c_precondition "server start failed"; return 3; }
  wait_ready || { bug4c_precondition "server not ready"; return 3; }
  mkdir -p "$work" || return 3

  (cd "$here" && BOT_NAME=Bot1 BUG4_DIR="$work" exec node bug4crowd.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  if ! wait_log "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" 120; then
    bug4c_abort "bot did not join"; return 3
  fi
  name=$(grep -E "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" "$LOG" | head -n 1 \
    | sed -E "s|${LOG_PREFIX}(System chat: )?||; s| joined the game.*||")
  echo "bug4crowd: Paper name '$name'"
  if ! bug4_wait_file "$work/pos" 30 "$bot_pid"; then
    bug4c_abort "bot sent no position"; return 3
  fi
  read -r bx by bz < "$work/pos"
  echo "bug4crowd: bot block $bx $by $bz"

  # Creative first, so no mob can hurt the bot.
  if ! bug4_cmd "gamemode creative $name" 'game ?mode|No player was found|<--\[HERE\]' \
     || [[ $BUG4_LINE != *reative* ]]; then
    bug4c_abort "gamemode creative failed: ${BUG4_LINE#*]: }"; return 3
  fi
  echo "bug4crowd: gamemode -> ${BUG4_LINE#*]: }"
  # Peaceful would remove the zombies and spiders, so use easy.
  bug4_cmd "difficulty easy" 'difficulty|<--\[HERE\]' && echo "bug4crowd: difficulty -> ${BUG4_LINE#*]: }"
  bug4_cmd "kill @e[type=!minecraft:player]" 'Killed|No entity was found|<--\[HERE\]' || true

  # One summon per mob, each with a unique name the bot can read from its
  # add_entity metadata. Spread on a golden-angle spiral 4 to 13 blocks out.
  i=0
  set -- $BUG4C_MOBS
  while [ $# -ge 2 ]; do
    for ((n = 0; n < $2; n++)); do
      local tags='"b4c"' xz
      if ((i % 3 == 0)); then tags='"b4c","b4fast"'; fi
      xz=$(awk -v i="$i" -v x="$bx" -v z="$bz" 'BEGIN { a = i * 2.39996; r = 4 + i % 10;
        printf "%.2f %.2f", x + 0.5 + r * cos(a), z + 0.5 + r * sin(a) }')
      send "summon minecraft:$1 ${xz% *} $by ${xz#* } {Tags:[$tags],CustomName:\"b4m$i\",PersistenceRequired:1b}" || true
      i=$((i + 1))
      sleep 0.05
    done
    shift 2
  done
  echo "bug4crowd: sent $i summon commands"
  sleep 2
  bug4_cmd "effect give @e[tag=b4c] minecraft:resistance 1000000 4 true" \
    'Applied effect|Unable|No entity|<--\[HERE\]' && echo "bug4crowd: effect -> ${BUG4_LINE#*]: }"
  bug4_cmd "execute as @e[tag=b4fast] run attribute @s minecraft:movement_speed base set 0.4" \
    'value for attribute|has no attribute|No entity|<--\[HERE\]' && echo "bug4crowd: fast -> ${BUG4_LINE#*]: }"
  count=0
  if bug4_cmd "execute if entity @e[tag=b4c]" 'Test passed, count: [0-9]+|Test failed|<--\[HERE\]'; then
    count=$(printf '%s\n' "$BUG4_LINE" | grep -oE 'count: [0-9]+' | grep -oE '[0-9]+' || echo 0)
  fi
  echo "bug4crowd: server mob count $count (summon answers: $(grep -c 'ummoned new' "$LOG" || true))"
  if [ "${count:-0}" -lt 50 ]; then
    bug4c_abort "only ${count:-0} mobs exist on the server"; return 3
  fi

  if ! bug4_put wander "$count"; then bug4c_abort "bot did not start the wander phase"; return 3; fi
  echo "bug4crowd: wandering for $BUG4C_WANDER_SECS s"
  sleep "$BUG4C_WANDER_SECS"

  if ! bug4_cmd "tick freeze" 'frozen|freeze|<--\[HERE\]|Unknown' \
     || [[ $BUG4_LINE == *HERE* || $BUG4_LINE == *nknown* ]]; then
    bug4c_abort "tick freeze failed: ${BUG4_LINE#*]: }"; return 3
  fi
  echo "bug4crowd: freeze -> ${BUG4_LINE#*]: }"
  # Geyser lerps each Java move over 3 ticks (150 ms); give it 0.5 s.
  sleep 0.5
  if ! bug4_put snap go; then bug4c_abort "bot did not take the snapshot"; return 3; fi

  # Server Pos of every mob: one line per mob, "b4mN has the following entity data: [x, y, z]".
  n=$(wc -l < "$LOG")
  send "execute as @e[tag=b4c] run data get entity @s Pos" || true
  last=-1
  for ((i = 0; i < 100; i++)); do
    sleep 0.2
    lines=$(tail -n +"$((n + 1))" "$LOG" | grep -oE 'b4m[0-9]+ has the following entity data: \[[^]]*\]' \
      | sed -E 's/ has the following entity data: \[/ /; s/[dD]?\]$//; s/[dD]?, / /g' \
      | awk 'NF == 4 { printf "%s %.6f %.6f %.6f\n", $1, $2, $3, $4 }' || true)
    got=$(printf '%s' "$lines" | grep -c . || true)
    if [ "$got" -ge "$count" ] || { [ "$got" -gt 0 ] && [ "$got" -eq "$last" ] && ((i >= 25)); }; then break; fi
    last=$got
  done
  echo "bug4crowd: server positions read for $got of $count mobs"
  printf '%s\n' "$lines" | head -n 3 | sed 's/^/bug4crowd: server Pos /'
  if [ "$got" -lt 50 ]; then
    tail -n +"$((n + 1))" "$LOG" | head -n 5
    bug4c_abort "server positions for only $got mobs"; return 3
  fi
  if ! bug4_put truth "$lines"; then bug4c_abort "bot did not read the server positions"; return 3; fi

  bug4_put end go || true
  bug4_stop_bot "$bot_pid"
  send "tick unfreeze" || true
  echo "bug4crowd: bot log:"; cat "$work/bot.log"
  local blocks
  blocks=$(exception_blocks) || true
  if [ -n "$blocks" ]; then
    echo "bug4crowd: exception blocks in latest.log (diagnostic):"; printf '%s\n' "$blocks"
  fi

  bres=$(cat "$work/result" 2>/dev/null || true)
  echo "bug4crowd: bot result: ${bres:-none}"
  case $bres in
    PASS*) rc=0; echo "bug4crowd: PASS every mob's Bedrock position matched the server's: ${bres#PASS }" ;;
    FAIL*) rc=1; echo "bug4crowd: FAIL some mob's Bedrock position was off by more than the limit: ${bres#FAIL }" ;;
    *) rc=3; bug4c_precondition "bot gave no result (${bres:-none})" ;;
  esac
  return "$rc"
}
