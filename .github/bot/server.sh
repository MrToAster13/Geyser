#!/usr/bin/env bash
# Paper test server for bot checks. Source this file, then call the functions.
# Commands reach Paper through a FIFO on stdin. RCON stays off.
set -euo pipefail

PAPER_URL='https://fill-data.papermc.io/v1/objects/580c266b6526bb34752e9c2c274be025f763af1ce5b3fa662fa2b3006f966c13/paper-26.3-177.jar'
PAPER_SHA='580c266b6526bb34752e9c2c274be025f763af1ce5b3fa662fa2b3006f966c13'
FLOODGATE_URL='https://download.geysermc.org/v2/projects/floodgate/versions/2.2.5/builds/141/downloads/spigot'
FLOODGATE_SHA='21570aff9ce17d6983928e8552777760e1ede5050026b04c686b0ae112e6fd7e'

# Paper latest.log line start: [HH:MM:SS] [thread/LEVEL]: (POSIX ERE).
LOG_PREFIX='^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] \[[^]]*/[A-Z]+\]: '

SERVER_DIR=${SERVER_DIR:-$PWD/server}
LOG="$SERVER_DIR/logs/latest.log"

fetch() {
  local url=$1 sha=$2 out=$3
  curl -fsSL --retry 3 -o "$out" "$url" || return 1
  echo "$sha  $out" | sha256sum -c - || { rm -f "$out"; return 1; }
}

# Callers run these functions inside `if`, where errexit is off,
# so every step that can fail ends in `|| return 1`.

# setup_server <geyser jar> <auth-type: floodgate|offline>
setup_server() {
  local jar=$1 auth=$2
  rm -rf "$SERVER_DIR" || return 1
  mkdir -p "$SERVER_DIR/plugins/Geyser-Spigot" || return 1
  fetch "$PAPER_URL" "$PAPER_SHA" "$SERVER_DIR/paper.jar" || return 1
  cp "$jar" "$SERVER_DIR/plugins/Geyser-Spigot.jar" || return 1
  if [ "$auth" = floodgate ]; then
    fetch "$FLOODGATE_URL" "$FLOODGATE_SHA" "$SERVER_DIR/plugins/floodgate-spigot.jar" || return 1
  fi
  echo 'eula=true' > "$SERVER_DIR/eula.txt" || return 1
  cat > "$SERVER_DIR/server.properties" <<'PROPS' || return 1
online-mode=false
enable-rcon=false
spawn-protection=0
level-type=minecraft\:flat
generate-structures=false
view-distance=4
simulation-distance=4
PROPS
  cat > "$SERVER_DIR/plugins/Geyser-Spigot/config.yml" <<CFG || return 1
bedrock:
  port: 19132
java:
  auth-type: $auth
advanced:
  bedrock:
    validate-bedrock-login: false
config-version: 9
CFG
}

start_server() {
  (
    cd "$SERVER_DIR" || exit 1
    rm -f in.fifo
    mkfifo in.fifo || exit 1
    # Opening the FIFO read-write keeps a writer, so Paper never reads EOF.
    nohup java -Xmx2G -Dterminal.jline=false -Dterminal.ansi=false -jar paper.jar nogui \
      0<>in.fifo > console.out 2>&1 &
    echo $! > server.pid
  ) || return 1
}

# send <command>. Opening the FIFO read-write never blocks,
# even after the server has exited and no reader is left.
send() {
  echo "$1" 1<>"$SERVER_DIR/in.fifo"
}

# wait_log <ERE> <timeout s>
wait_log() {
  local re=$1 t=$2 i
  for ((i = 0; i < t; i++)); do
    if [ -f "$LOG" ] && grep -qE "$re" "$LOG"; then return 0; fi
    kill -0 "$(cat "$SERVER_DIR/server.pid")" 2>/dev/null || { echo "server exited" >&2; return 1; }
    sleep 1
  done
  echo "timeout waiting for: $re" >&2
  return 1
}

wait_ready() {
  wait_log 'Done \([0-9.]+s\)!' 300 || return 1
  # R17-a self-test: the prefix regex must match the Done line.
  grep -E "$LOG_PREFIX" "$LOG" | grep -q 'Done (' \
    || { echo "prefix regex matched no Done line" >&2; return 1; }
  echo "prefix self-test ok: $(grep -cE "$LOG_PREFIX" "$LOG") prefixed lines"
}

# cmd <command> <ERE expected in latest.log> [timeout s, default 10]
cmd() {
  send "$1" || return 1
  wait_log "$2" "${3:-10}"
}

stop_server() {
  local pid
  pid=$(cat "$SERVER_DIR/server.pid" 2>/dev/null) || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  send stop || true
  for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  kill -9 "$pid" 2>/dev/null || true
}

# Prints every exception block in latest.log (R15-a, R16-a, R17-a).
# A block is a prefixed line plus the unprefixed lines after it.
# Blocks are separated by a line holding only "----".
exception_blocks() {
  local line block='' bad=0 tab=$'\t'
  local exc='[A-Za-z0-9_$]+(Exception|Error)(:|$)'
  [ -f "$LOG" ] || { echo "no $LOG" >&2; return 1; }
  flush() {
    if [ -n "$block" ] && [ "$bad" -eq 1 ]; then printf '%s----\n' "$block"; fi
    block=''; bad=0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ $line =~ $LOG_PREFIX ]]; then flush; fi
    block+="$line"$'\n'
    if [[ $line =~ $exc || $line == *'Could not translate packet'* \
          || $line == "${tab}at "* || $line == 'Caused by:'* ]]; then bad=1; fi
  done < "$LOG"
  flush
}
