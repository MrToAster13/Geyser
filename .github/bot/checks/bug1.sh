#!/usr/bin/env bash
# Bug 1: a Bedrock player cannot till grass with a hoe.
# Source after server.sh. check_bug1 returns 0 PASS (grass became farmland),
# 1 FAIL (all preconditions held and the block stayed unchanged),
# 3 precondition not met (prints which one).
# Uses $jar, $auth and $here from run.sh.

BUG1_LINE=''

# bug1_cmd <command> <ERE> [timeout s]: sends a console command and waits for
# the ERE in latest.log lines written after the send. The matched line goes
# to BUG1_LINE. Earlier lines never match, so repeated results like
# "Test passed" are read per command.
bug1_cmd() {
  local n i
  n=$(wc -l < "$LOG") || return 1
  send "$1" || return 1
  for ((i = 0; i < ${3:-10}; i++)); do
    BUG1_LINE=$(tail -n +"$((n + 1))" "$LOG" | grep -E "$2" | head -n 1 || true)
    if [ -n "$BUG1_LINE" ]; then return 0; fi
    sleep 1
  done
  echo "bug1: timeout waiting for '$2' after: $1"
  return 1
}

# bug1_test <execute condition>: 0 when "Test passed", 1 when "Test failed",
# 2 when no result line appears.
bug1_test() {
  bug1_cmd "execute $1" 'Test (passed|failed)' 10 || return 2
  echo "bug1: execute $1 -> ${BUG1_LINE#*]: }"
  case $BUG1_LINE in *'Test passed'*) return 0 ;; *) return 1 ;; esac
}

# bug1_wait_file <path> <timeout s> <bot pid>
bug1_wait_file() {
  local i
  for ((i = 0; i < $2; i++)); do
    if [ -f "$1" ]; then return 0; fi
    kill -0 "$3" 2>/dev/null || { echo "bug1: bot exited before $(basename "$1")"; return 1; }
    sleep 1
  done
  echo "bug1: timeout waiting for $(basename "$1")"
  return 1
}

bug1_precondition() {
  echo "bug1: PRECONDITION not met: $*"
  echo "check=bug1 outcome=PRECONDITION" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

bug1_stop_bot() {
  local pid=$1 i
  for i in $(seq 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

check_bug1() {
  local work bot_pid name x y z rc=1
  work="$SERVER_DIR/bug1"
  setup_server "$jar" "$auth" || { bug1_precondition "server setup failed"; return 3; }
  # Geyser debug output shows a held-item desync or a dropped click.
  echo 'debug-mode: true' >> "$SERVER_DIR/plugins/Geyser-Spigot/config.yml" || return 3
  start_server || { bug1_precondition "server start failed"; return 3; }
  wait_ready || { bug1_precondition "server not ready"; return 3; }
  mkdir -p "$work" || return 3

  (cd "$here" && BOT_NAME=Bot1 BUG1_DIR="$work" exec node bug1.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  if ! wait_log "${LOG_PREFIX}\.?Bot1 joined the game" 120; then
    cat "$work/bot.log"; bug1_stop_bot "$bot_pid"
    bug1_precondition "bot did not join"; return 3
  fi
  # The join line gives the exact name Paper uses (Floodgate adds a prefix).
  name=$(grep -E "${LOG_PREFIX}\.?Bot1 joined the game" "$LOG" | head -n 1 \
    | sed -E "s/${LOG_PREFIX}//; s/ joined the game.*//")
  echo "bug1: Paper name '$name'"

  if ! bug1_wait_file "$work/target" 30 "$bot_pid"; then
    cat "$work/bot.log"; bug1_stop_bot "$bot_pid"
    bug1_precondition "bot picked no target block"; return 3
  fi
  read -r x y z < "$work/target"
  echo "bug1: target block $x $y $z"

  # Precondition setup. Grass is set twice (dirt, then grass) so each setblock
  # changes the block and logs a result line, and Geyser sends update_block.
  if ! { bug1_cmd "setblock $x $y $z minecraft:dirt" 'Changed the block|Could not set' \
      && bug1_cmd "setblock $x $y $z minecraft:grass_block" 'Changed the block|Could not set' \
      && bug1_cmd "item replace entity $name hotbar.0 with minecraft:iron_hoe" \
           'Replaced a slot|No (player|entity|targets)|Unknown|<--\[HERE\]'; }; then
    bug1_stop_bot "$bot_pid"; bug1_precondition "setup commands failed"; return 3
  fi
  echo "bug1: item replace -> ${BUG1_LINE#*]: }"
  # Dry farmland turns back to dirt on a random tick; stop random ticks so a
  # tilled block stays farmland until the test reads it. Name changed in 1.21.11.
  bug1_cmd "gamerule random_tick_speed 0" 'is now set to|Unknown|Incorrect|<--\[HERE\]' \
    && echo "bug1: gamerule -> ${BUG1_LINE#*]: }"
  case $BUG1_LINE in
    *'is now set to'*) ;;
    *) bug1_cmd "gamerule randomTickSpeed 0" 'is now set to|Unknown|Incorrect|<--\[HERE\]' \
         && echo "bug1: gamerule -> ${BUG1_LINE#*]: }" ;;
  esac

  # Server-side preconditions (R2-e): block placed, air above, hoe held, survival.
  local why=''
  bug1_test "if block $x $y $z minecraft:grass_block" || why+=" target is not grass_block;"
  bug1_test "if block $x $((y + 1)) $z minecraft:air" || why+=" block above target is not air;"
  bug1_test "if items entity $name weapon.mainhand minecraft:iron_hoe" || why+=" main hand is not iron_hoe;"
  bug1_test "as $name if entity @s[gamemode=survival]" || why+=" bot not in survival;"
  if [ -n "$why" ]; then
    bug1_stop_bot "$bot_pid"; bug1_precondition "$why"; return 3
  fi

  touch "$work/go" || return 3
  if ! bug1_wait_file "$work/used" 30 "$bot_pid"; then
    bug1_stop_bot "$bot_pid"; cat "$work/bot.log"
    bug1_precondition "bot did not send the click (see bot log)"; return 3
  fi
  # Let the server process the click before reading the block.
  sleep 3

  if bug1_test "if block $x $y $z minecraft:farmland"; then
    rc=0
  else
    rc=$?
    [ "$rc" -eq 2 ] && rc=3
  fi
  # Diagnostics only: what the block is now, and whether the hoe lost durability.
  bug1_test "if block $x $y $z minecraft:grass_block" || true
  bug1_test "if items entity $name weapon.mainhand minecraft:iron_hoe[minecraft:damage=1]" || true

  bug1_stop_bot "$bot_pid"
  echo "bug1: bot log:"; cat "$work/bot.log"
  if grep -q 'PRECONDITION' "$work/bot.log"; then
    bug1_precondition "bot-side precondition failed"; return 3
  fi
  echo "bug1: Geyser debug lines about the click:"
  grep -E 'held item has desynced|Packet: InventoryTransactionPacket|Unhandled item use' "$LOG" | head -n 20 || true
  local blocks
  blocks=$(exception_blocks) || true
  if [ -n "$blocks" ]; then
    echo "bug1: exception blocks in latest.log (diagnostic):"; printf '%s\n' "$blocks"
  fi

  case $rc in
    0) echo "bug1: PASS grass at $x $y $z became farmland" ;;
    1) echo "bug1: FAIL grass at $x $y $z did not become farmland after the hoe click" ;;
    *) bug1_precondition "no result for the farmland test" ;;
  esac
  return "$rc"
}
