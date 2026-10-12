// Bug 7 bot: joins as an Android phone would and stays STAY_SECS after spawn.
// Login client data: DeviceOS 1 (Android), UIProfile 1 (pocket),
// CurrentInputMode and DefaultInputMode 2 (touch). After spawn it sends
// player_auth_input every 50 ms with input_mode touch, play_mode normal and
// interaction_model touch, standing still at the position Geyser last sent.
// Exit 0: stayed. Exit 1: kick, disconnect, error or no spawn. Exit 2: bad env.
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot7'
const stay = Number(process.env.STAY_SECS || 30)
const spawnTimeout = Number(process.env.SPAWN_TIMEOUT_SECS || 120)
if (!(stay > 0) || !(spawnTimeout > 0)) {
  console.log(`bug7-bot ${name}: FAIL bad STAY_SECS or SPAWN_TIMEOUT_SECS`)
  process.exit(2)
}
const log = (msg) => console.log(`bug7-bot ${name}: ${msg}`)

const client = bedrock.createClient({
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51',
  // bedrock-protocol 3.60.1 login.js: options.skinData is merged over the
  // client data, then DeviceOS is set from options.deviceOS.
  deviceOS: 1,
  skinData: { UIProfile: 1, CurrentInputMode: 2, DefaultInputMode: 2 }
})

let done = false
let inputTimer = null
let sent = 0
function finish (code, why) {
  if (done) return
  done = true
  clearInterval(inputTimer)
  log(`${code === 0 ? 'PASS' : 'FAIL'} ${why} (player_auth_input sent: ${sent})`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}

// Print the client data fields the server will read, from the signed JWT.
client.on('loggingIn', () => {
  try {
    const d = JSON.parse(Buffer.from(client.clientUserChain.split('.')[1], 'base64url').toString())
    log(`client data DeviceOS=${d.DeviceOS} UIProfile=${d.UIProfile} ` +
      `CurrentInputMode=${d.CurrentInputMode} DefaultInputMode=${d.DefaultInputMode}`)
  } catch (e) {
    log(`could not decode client data: ${e.message}`)
  }
})

let pos = null // Bedrock (eye level) position Geyser last sent for us
client.on('start_game', (p) => { pos = p.player_position })
client.on('move_player', (p) => {
  if (client.startGameData && BigInt(p.runtime_id) === BigInt(client.entityId)) pos = p.position
})

const spawnTimer = setTimeout(() => finish(1, `no spawn within ${spawnTimeout} s`), spawnTimeout * 1000)

let tick = 0n
function sendInput () {
  if (!pos) return
  tick += 1n
  client.queue('player_auth_input', {
    pitch: 0,
    yaw: 0,
    position: { x: pos.x, y: pos.y, z: pos.z },
    move_vector: { x: 0, z: 0 },
    head_yaw: 0,
    input_data: [],
    input_mode: 'touch',
    play_mode: 'normal',
    interaction_model: 'touch',
    interact_rotation: { x: 0, z: 0 },
    tick,
    delta: { x: 0, y: 0, z: 0 },
    analogue_move_vector: { x: 0, z: 0 },
    camera_orientation: { x: 0, y: 0, z: 1 },
    raw_move_vector: { x: 0, z: 0 }
  })
  sent++
}

client.on('spawn', () => {
  clearTimeout(spawnTimer)
  log(`spawned at ${pos ? `${pos.x.toFixed(2)} ${pos.y.toFixed(2)} ${pos.z.toFixed(2)}` : 'unknown position'}, staying ${stay} s`)
  inputTimer = setInterval(() => {
    try { sendInput() } catch (e) { finish(1, `player_auth_input write failed: ${e.stack || e}`) }
  }, 50)
  setTimeout(() => finish(0, `stayed ${stay} s`), stay * 1000)
})
client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
