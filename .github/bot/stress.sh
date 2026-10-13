#!/usr/bin/env bash
# Entity stress for bot checks. The checks call it only when STRESS=1, which
# only the run.sh checks bug2stress, bug3stress, bug6stress and bug7stress
# set. nightly-merge.yml runs every run.sh check, so those four gate the
# nightly release like the plain checks. Source after server.sh.
#
# stress_start <mixed|passive> [x y z] summons STRESS_MOBS (default 80) mobs
# with AI on, 4 to 18 blocks from the centre (block x y z, or the console's
# position, world spawn, when no centre is given). It confirms the count from
# the server, starts a background loop that sends one random entity event
# every 100 to 250 ms, and returns after STRESS_WARMUP seconds (default 15).
# stress_stop ends the loop and prints the event count, the mobs still alive
# and the failed-command counts. It is a no-op when no loop runs. It sets
# STRESS_BAD when the stress did not do its job (see stress_stop); checks
# call stress_ok after stress_stop and report PRECONDITION instead of PASS.
#
# Every stress mob carries the tag "stress" and every event selects through
# that tag, so no event targets a player. Mobs, items, arrows and snowballs
# never appear and teleports never land within 4 blocks of a player;
# lightning never strikes within 13. Monsters get follow_range 0.
# STRESS_AVOID="x,y,z;x,y,z" keeps new mobs at least 7 blocks, event summons
# 6 and lightning 8 blocks from those points (bug6 cushion spots). A short
# teleport starts at least 12 blocks away and moves at most 4 per axis.
# Passive mode (bug3) summons no monsters: a monster within 8 blocks of a bed
# stops the player sleeping. Villagers stay out too, they claim beds at night.
# Event feedback never contains "time", "tick" or "Test", which bug3 reads.
#
# STRESS_SEED seeds RANDOM (default: the epoch). Run k of a check uses
# STRESS_SEED + k * 7919, so one seed reproduces the command stream of every
# run of a check. Which mob each command hits (sort=random) and mob AI stay
# server-side random.

STRESS_PID=''
STRESS_RUN=0
STRESS_LINE=''
STRESS_LINE0=0
STRESS_MODE=mixed
STRESS_CALM_NEXT=0
STRESS_FORCED=''
STRESS_CX='' STRESS_CY='' STRESS_CZ=''
STRESS_XYZ=''
STRESS_K=0
STRESS_MOBS=${STRESS_MOBS:-80}
STRESS_WARMUP=${STRESS_WARMUP:-15}
STRESS_AVOID=${STRESS_AVOID:-}
STRESS_SEED=${STRESS_SEED:-$(date +%s)}
STRESS_DIR=''
STRESS_COUNT_FILE=''
# Why the last stress run is not valid, empty when it is. Set by stress_stop.
STRESS_BAD=''
# Most data failures (as a percentage of events sent) a valid stress run has.
# The passing stress runs on integ/26.3 (bug2stress, bug3stress, bug6stress,
# bug7stress) counted 0 or 1 data failure lines each (the 1 was bug3's own
# time query, not an event), against hundreds of events per run. 5% leaves
# room for a few odd failures (a mount onto a mob that just died) and still
# trips when an event kind that is 5% or more of the mix (every kind but
# lightning and mob summons) fails every time.
STRESS_MAX_DATA_PCT=${STRESS_MAX_DATA_PCT:-5}
STRESS_NAMES=(Biscuit Rex Mochi Pepper Luna Ziggy 'Zoë' '名前' Nugget Olive)
STRESS_COLORS=(red gold aqua green light_purple yellow)
# Failure feedback from commands that parsed but did nothing.
STRESS_FAILRE='No entity was found|Unable to |Could not |Nothing changed|does not have|[Cc]an.t |[Cc]annot |is not a |is already |failed'
# stress_stop drops bug3's "Test failed" and Paper's "Can't keep up" lines.
STRESS_NOTFAIL='Test failed|keep up'

# stress_cmd <command> <ERE> [timeout s]: sends a console command and waits for
# the ERE in latest.log lines written after the send. The line goes to STRESS_LINE.
stress_cmd() {
  local n i
  n=$(wc -l < "$LOG") || return 1
  send "$1" || return 1
  for ((i = 0; i < ${3:-10}; i++)); do
    STRESS_LINE=$(tail -n +"$((n + 1))" "$LOG" | grep -E "$2" | head -n 1 || true)
    [ -n "$STRESS_LINE" ] && return 0
    sleep 1
  done
  return 1
}

# stress_pos <player name>: prints the player's block position "x y z".
stress_pos() {
  stress_cmd "data get entity $1 Pos" \
    'has the following entity data|No entity was found|Unknown or incomplete|Incorrect argument' 10 || return 1
  grep -q 'has the following entity data' <<< "$STRESS_LINE" || { echo "stress: ${STRESS_LINE#*]: }" >&2; return 1; }
  grep -oE -- '-?[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?d' <<< "${STRESS_LINE##*data: }" | tr -d d \
    | awk '{ v = $1 + 0; f = int(v); if (f > v) f--; p = p (NR > 1 ? " " : "") f } END { if (NR != 3) exit 1; print p }'
}

# stress_floor <number>: the block that holds a coordinate ("-7.5" gives "-8").
stress_floor() {
  local i=${1%%.*} f=
  case $1 in *.*) f=${1#*.} ;; esac
  i=$((i + 0))
  if [ "${1:0:1}" = - ] && [ -n "${f//0/}" ]; then i=$((i - 1)); fi
  echo "$i"
}

# stress_half <block>: the centre coordinate of a block ("-8" gives "-7.5").
stress_half() {
  if (($1 < 0)); then echo "-$((-$1 - 1)).5"; else echo "$1.5"; fi
}

# stress_point: picks a spot 4 to 18 blocks from the centre, outside the
# 7x7 square around it and at least 7 blocks from every STRESS_AVOID point.
# Sets STRESS_XYZ to the coordinates for summon or tp; callers add an
# "unless entity @a[distance=..4]" guard at that point.
stress_point() {
  local try dx dz x z a ax az ok
  for ((try = 0; try < 60; try++)); do
    dx=$((RANDOM % 37 - 18)); dz=$((RANDOM % 37 - 18))
    if ((dx * dx + dz * dz > 324)); then continue; fi
    if ((dx > -4 && dx < 4 && dz > -4 && dz < 4)); then continue; fi
    if [ -z "$STRESS_CX" ]; then STRESS_XYZ="~$dx ~ ~$dz"; return 0; fi
    x=$((STRESS_CX + dx)); z=$((STRESS_CZ + dz)); ok=1
    for a in ${STRESS_AVOID//;/ }; do
      ax=$(stress_floor "${a%%,*}"); az=$(stress_floor "${a##*,}")
      if (((x - ax) * (x - ax) + (z - az) * (z - az) < 49)); then ok=0; break; fi
    done
    if [ "$ok" = 1 ]; then STRESS_XYZ="$(stress_half "$x") $STRESS_CY $(stress_half "$z")"; return 0; fi
  done
  return 1
}

# stress_guard <r>: execute subcommands that pass only when @s is more than
# r blocks from every STRESS_AVOID point. They move the execution position,
# so an "at @s" must follow.
stress_guard() {
  local a g=''
  for a in ${STRESS_AVOID//;/ }; do g+="positioned ${a//,/ } unless entity @s[distance=..$1] "; done
  printf '%s' "$g"
}

# stress_send <command>: sends a loop command and records it in the event log.
stress_send() {
  send "$1"
  echo "$1"
}

stress_types() {
  if [ "$STRESS_MODE" = passive ]; then
    echo cow sheep pig chicken horse rabbit
  else
    echo cow sheep pig chicken horse villager rabbit wolf zombie spider
  fi
}

# stress_summon_nbt <type>: the summon NBT for a stress mob of that type.
# Monsters start with follow_range 0, so they never target the bot.
stress_summon_nbt() {
  case $1 in
    horse) echo '{Tags:["stress"],PersistenceRequired:1b,Tame:1b}' ;;
    # A helmet keeps zombies from burning in daylight.
    zombie) echo '{Tags:["stress"],PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:0.0d}],equipment:{head:{id:"minecraft:leather_helmet",count:1}}}' ;;
    spider) echo '{Tags:["stress"],PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:0.0d}]}' ;;
    *) echo '{Tags:["stress"],PersistenceRequired:1b}' ;;
  esac
}

# stress_summon_at <type>: the command that summons a stress mob at
# STRESS_XYZ unless a player is within 4 blocks of that point.
stress_summon_at() {
  printf 'execute positioned %s unless entity @a[distance=..4] run summon minecraft:%s ~ ~ ~ %s' \
    "$STRESS_XYZ" "$1" "$(stress_summon_nbt "$1")"
}

# stress_calm: every monster gets follow_range 0, so none targets the bot.
# It covers naturally spawned monsters. A villager turns into a witch on the
# bolt's tick, after a calm sent with the bolt, so the loop calms again on the
# event after a lightning event.
stress_calm() {
  local t
  for t in zombie spider witch slime zombie_villager; do
    send "execute as @e[type=minecraft:$t] run attribute @s minecraft:follow_range base set 0"
  done
}

# stress_event: one random entity event.
stress_event() {
  local m='@e[tag=stress,sort=random,limit=1]' r=$((RANDOM % 100)) x y w nbt types t
  if ((r < 17)); then
    x=(minecraft:generic minecraft:magic)
    stress_send "execute as $m run damage @s $((1 + RANDOM % 3)) ${x[RANDOM % 2]}"
  elif ((r < 32)); then
    x=(speed slowness glowing invisibility jump_boost resistance fire_resistance levitation weakness strength slow_falling)
    stress_send "execute as $m run effect gives @s minecraft:${x[RANDOM % ${#x[@]}]} $((3 + RANDOM % 6)) 0"
  elif ((r < 47)); then
    if ((RANDOM % 2)); then
      stress_send "execute as $m $(stress_guard 12)at @s positioned ~$((RANDOM % 9 - 4)) ~ ~$((RANDOM % 9 - 4)) unless entity @a[distance=..4] run tp @s ~ ~ ~"
    elif stress_point; then
      stress_send "execute as $m positioned $STRESS_XYZ unless entity @a[distance=..4] run tp @s ~ ~ ~"
    fi
  elif ((r < 57)); then
    stress_send 'execute as @e[tag=spick] run tag @s remove spick'
    stress_send "execute as $m run tag @s add spick"
    stress_send 'execute as @e[tag=spick] on passengers run ride @s dismount'
    stress_send 'execute as @e[tag=spick] on vehicle run ride @e[tag=spick,limit=1] dismount'
    if ((RANDOM % 4)); then
      stress_send 'execute as @e[tag=spick] at @s run ride @s mount @e[tag=stress,tag=!spick,sort=nearest,limit=1]'
    fi
    stress_send 'execute as @e[tag=spick] run tag @s remove spick'
  elif ((r < 71)); then
    if ((RANDOM % 10 < 3)); then
      stress_send 'execute as @e[tag=spick] run tag @s remove spick'
      stress_send 'execute as @e[tag=named,sort=random,limit=1] run tag @s add spick'
      stress_send 'execute as @e[tag=spick] run data remove entity @s CustomName'
      stress_send 'execute as @e[tag=spick] run data merge entity @s {CustomNameVisible:0b,Tags:["stress"]}'
    else
      STRESS_K=$((STRESS_K + 1))
      w="${STRESS_NAMES[RANDOM % ${#STRESS_NAMES[@]}]} $STRESS_K"
      if ((RANDOM % 3 == 0)); then
        nbt="{CustomName:{text:\"$w\",color:\"${STRESS_COLORS[RANDOM % ${#STRESS_COLORS[@]}]}\"}"
      else
        nbt="{CustomName:\"$w\""
      fi
      stress_send "execute as $m run data merge entity @s $nbt,CustomNameVisible:$((RANDOM % 2))b,Tags:[\"stress\",\"named\"]}"
    fi
  elif ((r < 83)); then
    y=$((RANDOM % 10))
    if [ "$STRESS_MODE" = mixed ] && ((y < 4)); then
      x=('armor.head iron_helmet' 'armor.head golden_helmet' 'armor.chest chainmail_chestplate'
         'armor.chest iron_chestplate' 'armor.legs leather_leggings' 'armor.legs golden_leggings'
         'armor.feet diamond_boots' 'armor.feet iron_boots')
      w=${x[RANDOM % ${#x[@]}]}
      stress_send "execute as @e[tag=stress,type=minecraft:zombie,sort=random,limit=1] run item replace entity @s ${w% *} with minecraft:${w#* }"
    elif ((y < 6)); then
      x=(iron_horse_armor golden_horse_armor diamond_horse_armor leather_horse_armor)
      stress_send "execute as @e[tag=stress,type=minecraft:horse,sort=random,limit=1] run item replace entity @s armor.body with minecraft:${x[RANDOM % ${#x[@]}]}"
    elif ((y < 8)); then
      x=(iron_sword bow torch name_tag golden_axe wheat)
      stress_send "execute as $m run item replace entity @s weapon.mainhand with minecraft:${x[RANDOM % ${#x[@]}]}"
    else
      stress_send "execute as $m run item replace entity @s weapon.offhand with minecraft:shield"
    fi
  elif ((r < 93)); then
    case $((RANDOM % 3)) in
      0) x=(apple bone feather wheat carrot emerald)
         stress_send "execute as $m $(stress_guard 6)at @s unless entity @a[distance=..4] run summon minecraft:item ~ ~1 ~ {Item:{id:\"minecraft:${x[RANDOM % ${#x[@]}]}\",count:1},PickupDelay:32767s}" ;;
      1) stress_send "execute as $m $(stress_guard 6)at @s unless entity @a[distance=..4] run summon minecraft:arrow ~ ~3 ~ {pickup:0b,Motion:[0.0d,-1.0d,0.0d]}" ;;
      *) stress_send "execute as $m $(stress_guard 6)at @s unless entity @a[distance=..4] run summon minecraft:snowball ~ ~3 ~ {Motion:[0.0d,-0.5d,0.0d]}" ;;
    esac
  elif ((r < 96)); then
    stress_send "execute as $m $(stress_guard 8)at @s unless entity @a[distance=..13] run summon minecraft:lightning_bolt ~ ~ ~"
    STRESS_CALM_NEXT=1
  else
    read -r -a types <<< "$(stress_types)"
    t=${types[RANDOM % ${#types[@]}]}
    if stress_point; then stress_send "$(stress_summon_at "$t")"; fi
  fi
}

stress_loop() {
  local n=0 spid
  spid=$(cat "$SERVER_DIR/server.pid" 2>/dev/null)
  while :; do
    if ((n % 20 == 0)) && ! kill -0 "$spid" 2>/dev/null; then
      echo "stress: server gone after $n events"; break
    fi
    if [ "$STRESS_MODE" = mixed ] && { ((n % 30 == 0)) || [ "$STRESS_CALM_NEXT" = 1 ]; }; then
      stress_calm
    fi
    STRESS_CALM_NEXT=0
    stress_event
    n=$((n + 1))
    echo "$n" > "$STRESS_COUNT_FILE"
    sleep "$(printf '0.%03d' $((100 + RANDOM % 151)))"
  done
}

# stress_count <tag>: tags every stress mob and prints how many the server tagged.
stress_count() {
  stress_cmd "tag @e[tag=stress] add $1" "Added tag '$1' to|Could not add tag|No entity was found" 15 || return 1
  case $STRESS_LINE in
    *"Added tag '$1' to "*" entities"*) grep -oE "to [0-9]+ entities" <<< "$STRESS_LINE" | grep -oE '[0-9]+' ;;
    *"Added tag '$1' to "*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# stress_start <mixed|passive> [x y z]
stress_start() {
  local types t i got min
  if [ -n "$STRESS_PID" ]; then stress_stop; fi
  STRESS_BAD=''
  STRESS_RUN=$((STRESS_RUN + 1))
  STRESS_MODE=${1:-mixed}
  STRESS_CX=${2:-}; STRESS_CY=${3:-}; STRESS_CZ=${4:-}
  if [ -n "$STRESS_AVOID" ] && [ -z "$STRESS_CX" ]; then
    echo "stress: STRESS_AVOID needs an explicit centre"; return 1
  fi
  RANDOM=$((STRESS_SEED + STRESS_RUN * 7919))
  local centre=spawn
  if [ -n "$STRESS_CX" ]; then centre="$STRESS_CX $STRESS_CY $STRESS_CZ"; fi
  echo "stress seed=$STRESS_SEED run=$STRESS_RUN mode=$STRESS_MODE centre=$centre avoid=${STRESS_AVOID:-none}"
  STRESS_DIR="${ARTIFACTS:-$PWD/bot-logs}/stress"
  mkdir -p "$STRESS_DIR" || return 1
  STRESS_COUNT_FILE="$STRESS_DIR/count-run$STRESS_RUN"
  echo 0 > "$STRESS_COUNT_FILE" || return 1
  STRESS_LINE0=$(wc -l < "$LOG") || return 1
  # Spawn chunks do not stay loaded, so before a player joins (bug7) mobs
  # summoned around spawn unload at once. Force-load the area instead.
  if [ -z "$STRESS_CX" ]; then
    stress_cmd 'forceload add ~-32 ~-32 ~32 ~32' \
      'to be force loaded|No chunks were marked|Too many chunks|Unknown or incomplete|Incorrect argument|<--\[HERE\]' 10 \
      || { echo "stress: no reply to forceload add"; return 1; }
    case $STRESS_LINE in
      *"to be force loaded"* | *"No chunks were marked"*) STRESS_FORCED=1 ;;
      *) echo "stress: forceload add failed: ${STRESS_LINE#*]: }"; return 1 ;;
    esac
    sleep 2
  fi

  read -r -a types <<< "$(stress_types)"
  for ((i = 0; i < STRESS_MOBS; i++)); do
    t=${types[i % ${#types[@]}]}
    stress_point || continue
    send "$(stress_summon_at "$t")" || return 1
    sleep 0.05
  done
  sleep 2
  if [ "$STRESS_MODE" = mixed ]; then stress_calm; fi
  got=$(stress_count "scount$STRESS_RUN") || got=0
  min=$((STRESS_MOBS * 3 / 4))
  echo "stress summoned=$got requested=$STRESS_MOBS"
  if [ "${got:-0}" -lt "$min" ]; then
    echo "stress: only ${got:-0} stress mobs alive, need $min"
    tail -n +"$((STRESS_LINE0 + 1))" "$LOG" | grep -E 'Unknown or incomplete|Incorrect argument|<--\[HERE\]|Summoned|Unable' | sort | uniq -c | sort -rn | head -n 10
    if [ -n "$STRESS_FORCED" ]; then send 'forceload remove ~-32 ~-32 ~32 ~32' || true; STRESS_FORCED=''; fi
    return 1
  fi

  (
    set +e
    trap - EXIT
    RANDOM=$((STRESS_SEED + STRESS_RUN * 7919 + 1))
    stress_loop
  ) >> "$STRESS_DIR/events-run$STRESS_RUN.log" 2>&1 &
  STRESS_PID=$!
  echo "stress loop pid=$STRESS_PID; warmup ${STRESS_WARMUP} s"
  sleep "$STRESS_WARMUP"
  if ! kill -0 "$STRESS_PID" 2>/dev/null; then
    echo "stress: the event loop exited during warmup"; stress_stop; return 1
  fi
  echo "stress running: $(cat "$STRESS_COUNT_FILE" 2>/dev/null) events so far"
}

# stress_ok: 0 when the last stress run was valid (or none ran), 1 with the
# reason in STRESS_BAD when it was not. Call after stress_stop.
stress_ok() {
  [ -z "$STRESS_BAD" ]
}

# stress_stop: ends the loop and reports. Safe to call twice. It always
# returns 0: run.sh's EXIT trap calls it under set -e, and a non-zero return
# there would skip stop_server and save_logs. The verdict goes to STRESS_BAD
# instead, read through stress_ok. The run is not valid when no event was
# sent, when latest.log holds any command parse error (a changed command
# syntax makes every event of that kind fail), or when data failures exceed
# STRESS_MAX_DATA_PCT percent of the events sent.
stress_stop() {
  [ -n "${STRESS_PID:-}" ] || return 0
  local pid=$STRESS_PID n alive=unknown parse=0 data=0 spid new
  STRESS_PID=''
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  n=$(cat "$STRESS_COUNT_FILE" 2>/dev/null) || n=0
  [[ $n =~ ^[0-9]+$ ]] || n=0
  spid=$(cat "$SERVER_DIR/server.pid" 2>/dev/null) || spid=''
  if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
    alive=$(stress_count "sdone$STRESS_RUN") || alive=unknown
    if [ -n "$STRESS_FORCED" ]; then send 'forceload remove ~-32 ~-32 ~32 ~32' || true; fi
  fi
  STRESS_FORCED=''
  new="$STRESS_DIR/log-run$STRESS_RUN.txt"
  tail -n +"$((STRESS_LINE0 + 1))" "$LOG" > "$new" 2>/dev/null || true
  # Brigadier marks every parse error with a "<--[HERE]" line; one error can
  # count twice here (message line and marker line), which only matters as > 0.
  parse=$(grep -cE 'Unknown or incomplete command|Incorrect argument|<--\[HERE\]' "$new" 2>/dev/null) || parse=0
  data=$(grep -E "$STRESS_FAILRE" "$new" 2>/dev/null | grep -cvE "$STRESS_NOTFAIL") || data=0
  echo "stress events=$n run=$STRESS_RUN seed=$STRESS_SEED alive_at_stop=${alive:-unknown}"
  echo "stress failed_commands parse=$parse data=$data (latest.log lines since stress_start)"
  if [ "$n" -eq 0 ]; then
    STRESS_BAD="entity stress sent no events"
  elif [ "$parse" -gt 0 ]; then
    STRESS_BAD="entity stress hit $parse command parse error lines"
  elif [ $((data * 100)) -gt $((n * STRESS_MAX_DATA_PCT)) ]; then
    STRESS_BAD="entity stress data failures $data of $n events, over $STRESS_MAX_DATA_PCT%"
  fi
  if [ -n "$STRESS_BAD" ]; then echo "stress: NOT VALID: $STRESS_BAD"; else echo "stress: valid"; fi
  if [ "$parse" -gt 0 ] || [ "$data" -gt 0 ]; then
    echo "stress: failure lines (count, text):"
    grep -E "Unknown or incomplete command|Incorrect argument|<--\[HERE\]|$STRESS_FAILRE" "$new" \
      | grep -vE "$STRESS_NOTFAIL" | sed -E "s|${LOG_PREFIX}(System chat: )?||" | sort | uniq -c | sort -rn | head -n 20 || true
  fi
  # Feedback histogram (first three words), to check every event command ran.
  sed -nE "s|${LOG_PREFIX}System chat: ||p" "$new" | awk '{ print $1, $2, $3 }' \
    | sort | uniq -c | sort -rn > "$STRESS_DIR/feedback-run$STRESS_RUN.txt" 2>/dev/null || true
  echo "stress: feedback histogram:"; head -n 25 "$STRESS_DIR/feedback-run$STRESS_RUN.txt" 2>/dev/null || true
  return 0
}
