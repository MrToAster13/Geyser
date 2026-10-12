# Bug 5 check: Java registry left unfrozen (D2, R2-e, R14-a, R16-a).
# Sourced by run.sh after server.sh. check_bug5 returns
#   0 PASS, 1 FAIL (signal string in latest.log), 3 precondition not met.
# Preconditions (R14-a): the datapack is enabled and the give command's
# result line names the bot's join-line name. Exception blocks are allowed
# only when one of their lines holds a signal string (R16-a); any other
# exception block makes the result "precondition not met".

BUG5_SIGNALS=('Failed to freeze Simple Java registry' 'Registry must be frozen')

# Prints the exception blocks that hold no signal string.
bug5_other_blocks() {
  local blocks line block='' s
  blocks=$(exception_blocks) || return 1
  while IFS= read -r line; do
    if [ "$line" = '----' ]; then
      local hit=0
      for s in "${BUG5_SIGNALS[@]}"; do
        if [[ $block == *"$s"* ]]; then hit=1; fi
      done
      if [ "$hit" -eq 0 ]; then printf '%s----\n' "$block"; fi
      block=''
    else
      block+="$line"$'\n'
    fi
  done <<< "$blocks"
}

# Paper's player name for the first bot in the join line.
bug5_join_name() {
  grep -E "$LOG_PREFIX.*joined the game" "$LOG" | head -n 1 \
    | sed -E "s#${LOG_PREFIX}(System chat: )?(.*) joined the game.*#\2#"
}

# Escapes ERE metacharacters so a player name matches literally.
bug5_ere_escape() {
  printf '%s' "$1" | sed -E 's#[][\.*^$+?(){}|]#\\&#g'
}

check_bug5() {
  local here_b5 bot_pid bot_rc=0 name name_re others s found=0
  here_b5=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

  setup_server "$jar" "$auth" || { echo "bug5: precondition not met: server setup failed"; return 3; }
  mkdir -p "$SERVER_DIR/world/datapacks" || return 3
  cp -r "$here_b5/bug5/datapack" "$SERVER_DIR/world/datapacks/bug5" || return 3
  start_server || { echo "bug5: precondition not met: server did not start"; return 3; }
  wait_ready || { echo "bug5: precondition not met: server not ready"; return 3; }

  # Precondition 1: the datapack is enabled.
  # Paper 26.3 logs console command feedback as "System chat: <text>".
  if ! cmd "datapack list enabled" "${LOG_PREFIX}(System chat: )?There (is|are) [0-9]+ data pack.*enabled: .*file/bug5" 15; then
    echo "bug5: precondition not met: datapack file/bug5 not enabled"
    grep -E 'data pack|datapack' "$LOG" || true
    return 3
  fi
  grep -E 'data pack.*enabled: ' "$LOG" | tail -n 1

  # The bot stays long enough for the give and the inventory update.
  (cd "$here_b5/.." && BOT_NAME=Bot5 STAY_SECS=45 node join.js) &
  bot_pid=$!

  if ! wait_log "$LOG_PREFIX.*joined the game" 150; then
    wait "$bot_pid" || true
    echo "bug5: precondition not met: no join line"
    return 3
  fi
  # Paper's player name for the bot (Floodgate adds a prefix), D1, R4-f.
  name=$(bug5_join_name)
  name_re=$(bug5_ere_escape "$name")
  [ -n "$name" ] || { wait "$bot_pid" || true; echo "bug5: precondition not met: empty join-line name"; return 3; }
  echo "bug5: join-line name '$name'"

  # Precondition 2: the give command's result line for that name.
  if ! cmd "give $name minecraft:enchanted_book[minecraft:stored_enchantments={\"bug5:test\":1}]" \
      "${LOG_PREFIX}(System chat: )?Gave 1 .* to $name_re( |$)" 15; then
    wait "$bot_pid" || true
    echo "bug5: precondition not met: no give result line for '$name'"
    grep -E 'Gave|give|Unknown|Malformed|No player' "$LOG" | tail -n 5 || true
    return 3
  fi
  grep -E "${LOG_PREFIX}(System chat: )?Gave 1 .* to $name_re( |$)" "$LOG" | tail -n 1

  wait "$bot_pid" || bot_rc=$?
  echo "bug5: bot exit $bot_rc (informational, R14-a)"
  sleep 2

  # Signal lines.
  for s in "${BUG5_SIGNALS[@]}"; do
    if grep -qF "$s" "$LOG"; then
      found=1
      echo "bug5: signal '$s' in latest.log:"
      grep -nF "$s" "$LOG" | head -n 5
    fi
  done

  # Any exception block without a signal string: precondition not met.
  others=$(bug5_other_blocks) || { echo "bug5: precondition not met: latest.log missing"; return 3; }
  if [ -n "$others" ]; then
    echo "bug5: precondition not met: exception blocks without a signal string:"
    printf '%s\n' "$others"
    return 3
  fi

  if [ "$found" -eq 1 ]; then
    echo "bug5: FAIL registry left unfrozen"
    return 1
  fi
  echo "bug5: PASS no signal string, no exception blocks"
  return 0
}
