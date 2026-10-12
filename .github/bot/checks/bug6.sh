#!/usr/bin/env bash
# Bug 6: cushions show several floating name tags on Bedrock.
# Sourced by run.sh after server.sh. check_bug6 returns 0 PASS, 1 FAIL,
# 3 precondition not met, and prints why.
#
# Java 26.3 cushions are entities (Geyser: CushionEntity, VanillaEntities CUSHION).
# A Java entity without a custom name shows no name tag, and a named one with
# CustomNameVisible shows exactly one. The bot records every add_entity,
# add_item_entity, add_player and set_entity_data packet and its Bedrock
# "nametag" metadata. Unnamed cushions fail on any name-carrying entity at their
# spot; the named control cushion fails on more than one. The control must carry
# its name, which proves the detector works (precondition). Every cushion's
# add_entity must arrive before anything is counted (R2-e).

# Flat world: grass top is y=-61, so entities stand at y=-60. These spots are
# near world spawn, inside the bot's view distance.
BUG6_PLAIN='6.5,-60,6.5;6.5,-60,10.5'
BUG6_CONTROL='12.5,-60,6.5'
BUG6_PROBE=bug6probe

# bug6_cmd_n <command> <ERE> <n> [timeout s]: send a console command and wait
# until latest.log holds at least n lines matching ERE.
bug6_cmd_n() {
  local re=$2 n=$3 t=${4:-15} i c
  send "$1" || return 1
  for ((i = 0; i < t; i++)); do
    c=$(grep -cE "$re" "$LOG" 2>/dev/null) || c=0
    [ "$c" -ge "$n" ] && return 0
    sleep 1
  done
  echo "timeout waiting for $n x '$re' after: $1" >&2
  return 1
}

# bug6_abort <bot pid> <bot log>: stop the bot and print what the server said.
bug6_abort() {
  kill "$1" 2>/dev/null; wait "$1" 2>/dev/null
  echo "PRECONDITION bug6: setup step failed; bot log and command feedback:"
  cat "$2"
  grep -E "${LOG_PREFIX}System chat: " "$LOG" || true
}

check_bug6() {
  local art=${ARTIFACTS:-$PWD/bot-logs} work botlog pid rc=0 name spot i blocks
  work=$(mktemp -d) || return 3
  mkdir -p "$art" || return 3
  botlog="$art/bug6-bot.log"

  setup_server "$jar" "$auth" || return 3
  start_server || return 3
  wait_ready || return 3

  (cd "$here" && BOT_NAME=Bot6 BUG6_DIR="$work" BUG6_PLAIN="$BUG6_PLAIN" \
    BUG6_CONTROL="$BUG6_CONTROL" BUG6_PROBE="$BUG6_PROBE" node bug6.js) > "$botlog" 2>&1 &
  pid=$!

  # Precondition: the bot spawned and Paper logged its join line.
  for ((i = 0; i < 150; i++)); do
    grep -q 'bug6 bot: spawned' "$botlog" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if ! grep -q 'bug6 bot: spawned' "$botlog"; then
    echo "PRECONDITION bug6: bot did not spawn"; cat "$botlog"; wait "$pid"; return 3
  fi
  wait_log "$LOG_PREFIX.*joined the game" 30 || { bug6_abort "$pid" "$botlog"; return 3; }
  name=$(sed -nE "s|${LOG_PREFIX}(.*) joined the game.*|\1|p" "$LOG" | tail -n1)
  echo "bug6: bot joined as '$name'"

  # Clear generated mobs so only the summoned cushions sit at the spots.
  cmd 'kill @e[type=!minecraft:player]' "${LOG_PREFIX}(System chat: )?(Killed |No entity was found)" 15 || { bug6_abort "$pid" "$botlog"; return 3; }
  i=0
  for spot in ${BUG6_PLAIN//;/ }; do
    i=$((i + 1))
    bug6_cmd_n "summon minecraft:cushion ${spot//,/ }" "${LOG_PREFIX}(System chat: )?Summoned new " "$i" || { bug6_abort "$pid" "$botlog"; return 3; }
  done
  bug6_cmd_n "summon minecraft:cushion ${BUG6_CONTROL//,/ } {CustomName:\"$BUG6_PROBE\",CustomNameVisible:1b}" \
    "${LOG_PREFIX}(System chat: )?Summoned new $BUG6_PROBE" 1 || { bug6_abort "$pid" "$botlog"; return 3; }
  # Let tracking, metadata and any extra entities reach the bot.
  sleep 8
  touch "$work/done"
  wait "$pid" || rc=$?
  cat "$botlog"
  grep -E "${LOG_PREFIX}(System chat: )?(Summoned new |Killed |No entity was found|Unable|Unknown|Incorrect)" "$LOG" || true

  blocks=$(exception_blocks) || return 3
  if [ -n "$blocks" ]; then
    echo "bug6: exception blocks in latest.log:"; printf '%s\n' "$blocks"
    # A name tag failure stands on its own; otherwise a pass is not trusted.
    [ "$rc" -eq 1 ] || rc=3
  fi
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) echo "PRECONDITION bug6: not met (bot exit $rc)"; return 3 ;;
  esac
}
