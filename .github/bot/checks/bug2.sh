#!/usr/bin/env bash
# Bug 2: crafting recipe mappings wrong, and crafting slow.
# Source after server.sh. check_bug2 returns 0 PASS (every subset recipe
# present and complete), 1 FAIL (a subset recipe is missing or wrong),
# 3 precondition not met or result unverified (prints why).
# Uses $jar, $auth and $here from run.sh.
# Recipes and item tags come from versions/26.3/paper-26.3.jar after the
# first boot (R3-f, R4-h); the bot side is bug2.js; the comparison is
# checks/bug2/compare.py. The slowness half is a timing proxy only (D2).

bug2_precondition() {
  echo "bug2: PRECONDITION not met: $*"
  echo "check=bug2 outcome=PRECONDITION" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

bug2_stop_bot() {
  local pid=$1 i
  for i in $(seq "${2:-5}"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

bug2_save() {
  mkdir -p "$ARTIFACTS/bug2" || return 0
  cp "$1"/bot.log "$1"/bot.json "$1"/compare.txt "$1"/jar-entries.txt "$ARTIFACTS/bug2/" 2>/dev/null || true
}

check_bug2() {
  local work pjar bot_pid name i rc bot_rc
  work="$SERVER_DIR/bug2"
  setup_server "$jar" "$auth" || { bug2_precondition "server setup failed"; return 3; }
  start_server || { bug2_precondition "server start failed"; return 3; }
  wait_ready || { bug2_precondition "server not ready"; return 3; }
  mkdir -p "$work/jar" || return 3

  # R4-h: list the jar's entries before trusting the location.
  pjar="$SERVER_DIR/versions/26.3/paper-26.3.jar"
  echo "bug2: jars under versions/:"; find "$SERVER_DIR/versions" -name '*.jar' 2>/dev/null || true
  if [ ! -f "$pjar" ]; then bug2_precondition "no $pjar"; return 3; fi
  unzip -Z1 "$pjar" > "$work/jar-entries.txt" || { bug2_precondition "cannot list $pjar"; return 3; }
  echo "bug2: $pjar entries: $(wc -l < "$work/jar-entries.txt") total," \
    "$(grep -c '^data/minecraft/recipe/.*\.json$' "$work/jar-entries.txt" || true) under data/minecraft/recipe," \
    "$(grep -c '^data/minecraft/tags/item/.*\.json$' "$work/jar-entries.txt" || true) under data/minecraft/tags/item"
  if ! grep -q '^data/minecraft/recipe/.*\.json$' "$work/jar-entries.txt" \
      || ! grep -q '^data/minecraft/tags/item/.*\.json$' "$work/jar-entries.txt"; then
    bug2_save "$work"; bug2_precondition "recipes or item tags not in $pjar"; return 3
  fi
  unzip -q -o "$pjar" 'data/minecraft/recipe/*' 'data/minecraft/tags/item/*' -d "$work/jar" \
    || { bug2_precondition "cannot extract recipes"; return 3; }

  (cd "$here" && BOT_NAME=Bot1 BUG2_DIR="$work" exec node bug2.js) > "$work/bot.log" 2>&1 &
  bot_pid=$!

  # Paper logs the join as "System chat: .Bot1 joined the game" (floodgate
  # prefix "."). LOG_PREFIX contains "/", so sed uses "|" as the delimiter.
  if ! wait_log "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" 120; then
    cat "$work/bot.log"; bug2_stop_bot "$bot_pid"; bug2_save "$work"
    bug2_precondition "bot did not join"; return 3
  fi
  name=$(grep -E "${LOG_PREFIX}(System chat: )?\.?Bot1 joined the game" "$LOG" | head -n 1 \
    | sed -E "s|${LOG_PREFIX}||; s|^System chat: ||; s| joined the game.*||")
  case $name in
    Bot1|.Bot1) ;;
    *) cat "$work/bot.log"; bug2_stop_bot "$bot_pid"; bug2_save "$work"
       bug2_precondition "cannot read the Paper name from the join line ('$name')"; return 3 ;;
  esac
  echo "bug2: Paper name '$name'"

  for ((i = 0; i < 60; i++)); do
    [ -f "$work/spawned" ] && break
    kill -0 "$bot_pid" 2>/dev/null || break
    sleep 1
  done
  if [ ! -f "$work/spawned" ]; then
    cat "$work/bot.log"; bug2_stop_bot "$bot_pid"; bug2_save "$work"
    bug2_precondition "bot did not spawn"; return 3
  fi

  # R5-b: give every recipe and confirm the result line.
  if ! cmd "recipe give $name *" \
      "${LOG_PREFIX}(System chat: )?(Unlocked [0-9]+ recipe(s|\(s\))? for|No new recipes|No player was found|Unknown or incomplete|Incorrect argument)" 30; then
    cat "$work/bot.log"; bug2_stop_bot "$bot_pid"; bug2_save "$work"
    bug2_precondition "no result line for recipe give"; return 3
  fi
  local give_line
  give_line=$(grep -E "${LOG_PREFIX}(System chat: )?(Unlocked [0-9]+ recipe(s|\(s\))? for|No new recipes|No player was found|Unknown or incomplete|Incorrect argument)" "$LOG" | tail -n 1)
  echo "bug2: recipe give -> ${give_line#*]: }"
  case $give_line in
    *Unlocked*) ;;
    *) bug2_stop_bot "$bot_pid"; bug2_save "$work"; bug2_precondition "recipe give did not unlock recipes"; return 3 ;;
  esac
  touch "$work/given" || return 3

  # The bot ends 10 s after the last crafting_data, at most 90 s after `given`.
  for ((i = 0; i < 120; i++)); do kill -0 "$bot_pid" 2>/dev/null || break; sleep 1; done
  bot_rc=0
  if kill -0 "$bot_pid" 2>/dev/null; then
    bug2_stop_bot "$bot_pid" 1; bot_rc=124
  else
    wait "$bot_pid" || bot_rc=$?
  fi
  echo "bug2: bot exit $bot_rc; bot log:"; cat "$work/bot.log"
  bug2_save "$work"
  if [ "$bot_rc" -ne 0 ] || [ ! -f "$work/bot.json" ]; then
    bug2_precondition "bot did not record the recipe set (exit $bot_rc)"; return 3
  fi

  # Slowness half (D2): timing proxy only.
  python3 -I -c '
import json, sys
b = json.load(open(sys.argv[1]))
p = b["packets"]
after = [x["at"] for x in p if x["afterGiven"]]
print("bug2: timing (ms from bot start): spawn %s, item_registry %s, crafting_data packets %d at %s, final %s"
      % (b["spawnedAt"], b["itemRegistryAt"], len(p), [x["at"] for x in p], b["lastCraftingAt"]))
print("bug2: timing proxy: spawn to final crafting_data %s ms; recipe give to last crafting_data %s ms; crafting_data sizes %s bytes"
      % (b["lastCraftingAt"] - b["spawnedAt"] if b["lastCraftingAt"] is not None else "n/a",
         (max(after) - b["givenAt"]) if after else "none after give", b["sizes"]))
if b["parseErrors"]:
    print("bug2: packet parse errors: %s" % b["parseErrors"][:5])
' "$work/bot.json" || true

  rc=0
  python3 -I "$here/checks/bug2/compare.py" "$work/jar" "$work/bot.json" > "$work/compare.txt" 2>&1 || rc=$?
  cat "$work/compare.txt"
  bug2_save "$work"

  local blocks
  blocks=$(exception_blocks) || true
  if [ -n "$blocks" ]; then
    echo "bug2: exception blocks in latest.log (diagnostic):"; printf '%s\n' "$blocks" | head -n 60
  fi

  case $rc in
    0) echo "bug2: PASS every recipe in the subset is present and complete; slowness unverified (proxy only)" ;;
    1) echo "bug2: FAIL subset recipes missing or wrong; slowness unverified (proxy only)" ;;
    3) bug2_precondition "comparison unverified (see above)" ;;
    *) bug2_precondition "comparison script error $rc"; rc=3 ;;
  esac
  return "$rc"
}
