#!/usr/bin/env bash
# Bug 4, crowd variant: about 90 named mobs walk under their own AI near a
# creative bot while a seeded loop sends random entity events. Then every mob
# gets NoAI and settles for a few seconds with the server still ticking, so
# Geyser's 3-tick lerps, knockback and falls finish. Only then does the server
# freeze, and the check compares the position Geyser gave the Bedrock client
# for every mob with the server's. Geyser (like the Java client) does not
# tick lerps while frozen, so freezing a moving crowd would measure lerp lag
# instead of lasting position error.
# Source after server.sh. check_bug4crowd returns 0 PASS, 1 FAIL (some mob
# is off by more than the limit), 3 precondition not met (prints which).
# Uses $jar, $auth and $here from run.sh, and the helpers in bug4.sh. It does
# not use any other stress script.
source "$here/checks/bug4.sh"

BUG4C_WANDER_SECS=${BUG4C_WANDER_SECS:-60}
# After the events every mob gets NoAI and the server keeps ticking this many
# seconds before the freeze, so riders are dismounted, short effects have run
# out and every pending lerp has finished when the positions are compared.
BUG4C_SETTLE_SECS=6
# Command parse errors. Brigadier follows each with a "...<--[HERE]" line,
# which also catches parse errors with other wording ("Can't find element").
BUG4C_ERR_RE='Unknown or incomplete command|Incorrect argument|<--\[HERE\]'
# Commands that parsed but did nothing. Printed only, see the event gate.
BUG4C_DATA_RE='No entity was found|Unable to |Could not |Nothing changed|[Cc]an.t |[Cc]annot |failed'

# bug4c_events <seconds> <mob count> <seed>: one random event every 100 to
# 250 ms on a random b4mN mob. Events that move a mob at once (tp, Motion,
# ride, dismount) are logged to $work/kicks as "b4mN epoch_ms" for the bot.
# Riders come only from mobs with i % 4 == 1, so the rest never ride.
# Writes "<total> <per-kind counts>" to $work/events.
bug4c_events() {
  local secs=$1 total=$2 end a b k ev=0 r
  local -a kinds=(damage damage_by effect tp motion projectile mount dismount) cnt=(0 0 0 0 0 0 0 0)
  local -a effects=(speed slowness jump_boost levitation)
  local -a shots=(arrow snowball)
  # Runs as a background job: one failed write must not end the loop.
  set +e
  RANDOM=$3
  : > "$work/kicks"
  end=$(($(date +%s%3N) + secs * 1000))
  while (($(date +%s%3N) < end)); do
    a="b4m$((RANDOM % total))"
    b="b4m$((RANDOM % total))"
    k=$((RANDOM % ${#kinds[@]}))
    case ${kinds[k]} in
      damage) send "damage @e[name=$a,limit=1] 1" ;;
      damage_by) send "damage @e[name=$a,limit=1] 1 minecraft:mob_attack by @e[name=$b,limit=1]" ;;
      effect) send "effect give @e[name=$a,limit=1] minecraft:${effects[RANDOM % 4]} 3 1 true" ;;
      tp)
        send "execute as @e[name=$a,limit=1] at @s run tp @s ~$((RANDOM % 7 - 3)) ~ ~$((RANDOM % 7 - 3))"
        echo "$a $(date +%s%3N)" >> "$work/kicks" ;;
      motion)
        send "data merge entity @e[name=$a,limit=1] {Motion:[$(awk -v r1=$RANDOM -v r2=$RANDOM -v r3=$RANDOM \
          'BEGIN { printf "%.2fd,%.2fd,%.2fd", (r1 % 161 - 80) / 100, (r2 % 51) / 100, (r3 % 161 - 80) / 100 }')]}"
        echo "$a $(date +%s%3N)" >> "$work/kicks" ;;
      projectile) send "execute at @e[name=$a,limit=1] run summon minecraft:${shots[RANDOM % 2]} ~ ~3 ~ {Motion:[0d,-1d,0d]}" ;;
      mount)
        r="b4m$((1 + 4 * (RANDOM % (total / 4))))"
        [ "$r" = "$b" ] && b="b4m$(((${b#b4m} + 2) % total))"
        send "ride @e[name=$r,limit=1] mount @e[name=$b,limit=1]"
        echo "$r $(date +%s%3N)" >> "$work/kicks" ;;
      dismount)
        r="b4m$((1 + 4 * (RANDOM % (total / 4))))"
        send "ride @e[name=$r,limit=1] dismount"
        echo "$r $(date +%s%3N)" >> "$work/kicks" ;;
    esac
    ev=$((ev + 1)); cnt[k]=$((cnt[k] + 1))
    sleep "0.$((100 + RANDOM % 151))"
  done
  r=''
  for k in "${!kinds[@]}"; do r+=" ${kinds[k]}=${cnt[k]}"; done
  echo "$ev$r" > "$work/events"
}

# bug4c_read_pos <count>: server Pos of every b4c mob into BUG4C_LINES as
# "b4mN x y z" lines and their number into BUG4C_GOT. Paper answers one line
# per mob, "b4mN has the following entity data: [x, y, z]".
bug4c_read_pos() {
  local n i last=-1
  BUG4C_LINES='' BUG4C_GOT=0
  n=$(wc -l < "$LOG")
  send "execute as @e[tag=b4c] run data get entity @s Pos" || true
  for ((i = 0; i < 100; i++)); do
    sleep 0.2
    BUG4C_LINES=$(tail -n +"$((n + 1))" "$LOG" | grep -oE 'b4m[0-9]+ has the following entity data: \[[^]]*\]' \
      | sed -E 's/ has the following entity data: \[/ /; s/[dD]?\]$//; s/[dD]?, / /g' \
      | awk 'NF == 4 { printf "%s %.6f %.6f %.6f\n", $1, $2, $3, $4 }' || true)
    BUG4C_GOT=$(printf '%s' "$BUG4C_LINES" | grep -c . || true)
    if [ "$BUG4C_GOT" -ge "$1" ] || { [ "$BUG4C_GOT" -gt 0 ] && [ "$BUG4C_GOT" -eq "$last" ] && ((i >= 25)); }; then break; fi
    last=$BUG4C_GOT
  done
  if [ "$BUG4C_GOT" -lt 50 ]; then tail -n +"$((n + 1))" "$LOG" | head -n 5; fi
}

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
  local work bot_pid name bx by bz count n i lines got rc bres seed ev_pid errs evn data bad=''
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
      # Resistance V from the first tick: in run 1 a wolf killed a sheep
      # before a later effect command reached it.
      send "summon minecraft:$1 ${xz% *} $by ${xz#* } {Tags:[$tags],CustomName:\"b4m$i\",PersistenceRequired:1b,active_effects:[{id:\"minecraft:resistance\",amplifier:4b,duration:-1,show_particles:0b}]}" || true
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
  # Paper answers "Test passed. Count: 92" when all 92 summons worked.
  if bug4_cmd "execute if entity @e[tag=b4c]" 'Test passed|Test failed|<--\[HERE\]'; then
    count=$(printf '%s\n' "$BUG4_LINE" | grep -oiE 'count: [0-9]+' | grep -oE '[0-9]+' || echo 0)
  fi
  echo "bug4crowd: server mob count $count (summon answers: $(grep -c 'ummoned new' "$LOG" || true))"
  if [ "${count:-0}" -lt 50 ]; then
    bug4c_abort "only ${count:-0} mobs exist on the server"; return 3
  fi

  if ! bug4_put wander "$count"; then bug4c_abort "bot did not start the wander phase"; return 3; fi
  seed=${STRESS_SEED:-$(date +%s)}
  echo "bug4crowd: random events for $((BUG4C_WANDER_SECS - BUG4C_SETTLE_SECS)) s, then NoAI and at least" \
    "$BUG4C_SETTLE_SECS s of settling before the freeze, STRESS_SEED=$seed"
  n=$(wc -l < "$LOG")
  bug4c_events "$((BUG4C_WANDER_SECS - BUG4C_SETTLE_SECS))" "$i" "$seed" &
  ev_pid=$!
  wait "$ev_pid" || true
  # Riders' positions follow their vehicle, so get everyone down first.
  send "execute as @e[tag=b4c] on passengers run ride @s dismount" || true
  # Give the dismount reply time to reach latest.log before counting errors.
  sleep 2
  errs=$(tail -n +"$((n + 1))" "$LOG" | grep -cE "$BUG4C_ERR_RE" || true)
  echo "bug4crowd: events sent: $(cat "$work/events" 2>/dev/null || echo none)"
  echo "bug4crowd: in-game command errors ($BUG4C_ERR_RE): $errs"
  tail -n +"$((n + 1))" "$LOG" | grep -A1 -E "$BUG4C_ERR_RE" | head -n 6 | sed 's/^/bug4crowd: error sample: /' || true
  echo "bug4crowd: jump events (tp, Motion, ride) logged: $(wc -l < "$work/kicks")"
  data=$(tail -n +"$((n + 1))" "$LOG" | grep -E "$BUG4C_DATA_RE" | grep -cv 'Test failed' || true)
  echo "bug4crowd: INFO event commands that parsed but did nothing ($BUG4C_DATA_RE): $data"
  # Event gate: the crowd test proves nothing when no event ran or when an
  # event command no longer parses (a syntax change would silently drop that
  # event kind). It turns a PASS into PRECONDITION; a FAIL stands. Data
  # failures do not gate yet: mount, damage_by and dismount pick random mobs
  # and can miss, and no CI run has measured their normal rate.
  evn=$(awk '{ print $1; exit }' "$work/events" 2>/dev/null || true)
  [[ $evn =~ ^[0-9]+$ ]] || evn=0
  if [ "$evn" -eq 0 ]; then bad="the event loop sent no events"
  elif [ "${errs:-0}" -gt 0 ]; then bad="$errs command parse error lines during the events"
  fi
  [ -z "$bad" ] || echo "bug4crowd: events NOT VALID: $bad"

  # Stop every mob, then let the server keep ticking so pending lerps,
  # knockback and falls finish before the freeze. The bot counts moves from
  # here on as settle moves, including any the NoAI change itself causes.
  if ! bug4_put settle go; then bug4c_abort "bot did not start the settle phase"; return 3; fi
  n=$(wc -l < "$LOG")
  if ! bug4_cmd "execute as @e[tag=b4c] run data merge entity @s {NoAI:1b}" \
     'Modified entity data of b4m|<--\[HERE\]' || [[ $BUG4_LINE == *HERE* ]]; then
    bug4c_abort "NoAI failed: ${BUG4_LINE#*]: }"; return 3
  fi
  sleep 0.5
  got=$(tail -n +"$((n + 1))" "$LOG" | grep -ciE 'Modified entity data of b4m' || true)
  echo "bug4crowd: NoAI set on $got of $count mobs"
  if [ "${got:-0}" -lt 50 ]; then bug4c_abort "NoAI set on only ${got:-0} mobs"; return 3; fi
  echo "bug4crowd: settling unfrozen for $BUG4C_SETTLE_SECS s"
  sleep "$BUG4C_SETTLE_SECS"

  # Server Pos just before the freeze; the bot compares it with the frozen
  # Pos to find mobs the server still moved.
  bug4c_read_pos "$count"
  echo "bug4crowd: server positions before the freeze read for $BUG4C_GOT of $count mobs"
  if [ "$BUG4C_GOT" -lt 50 ]; then bug4c_abort "pre-freeze server positions for only $BUG4C_GOT mobs"; return 3; fi
  if ! bug4_put pre "$BUG4C_LINES"; then bug4c_abort "bot did not read the pre-freeze positions"; return 3; fi

  # The time just before the freeze command, in epoch ms, tells the bot where
  # its "moved in the last second before the freeze" window ends.
  local tfreeze
  tfreeze=$(date +%s%3N)
  if ! bug4_cmd "tick freeze" 'frozen|freeze|<--\[HERE\]|Unknown' \
     || [[ $BUG4_LINE == *HERE* || $BUG4_LINE == *nknown* ]]; then
    bug4c_abort "tick freeze failed: ${BUG4_LINE#*]: }"; return 3
  fi
  echo "bug4crowd: freeze -> ${BUG4_LINE#*]: }"
  if ! bug4_put frozen "$tfreeze"; then bug4c_abort "bot did not note the freeze"; return 3; fi
  sleep 0.5
  if ! bug4_put snap go; then bug4c_abort "bot did not take the snapshot"; return 3; fi

  bug4c_read_pos "$count"
  got=$BUG4C_GOT lines=$BUG4C_LINES
  echo "bug4crowd: server positions read for $got of $count mobs"
  printf '%s\n' "$lines" | head -n 3 | sed 's/^/bug4crowd: server Pos /'
  if [ "$got" -lt 50 ]; then bug4c_abort "server positions for only $got mobs"; return 3; fi
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
    PASS*)
      if [ -n "$bad" ]; then
        rc=3; bug4c_precondition "bot PASS (${bres#PASS }) is void: $bad"
      else
        rc=0; echo "bug4crowd: PASS every settled mob's Bedrock position matched the server's: ${bres#PASS }"
      fi ;;
    FAIL*) rc=1; echo "bug4crowd: FAIL some settled mob's Bedrock position was off by more than the limit: ${bres#FAIL }" ;;
    *) rc=3; bug4c_precondition "bot gave no result (${bres:-none})" ;;
  esac
  return "$rc"
}
