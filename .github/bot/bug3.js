// Bug 3 bot: a Bedrock player gets kicked out of a bed by a teleport.
// Java 26.3 teleports a player to the bed head when they start sleeping.
// Before the upstream fix, Geyser passed that teleport on as move_player,
// and the Bedrock client wakes up when it is teleported. This bot does not
// simulate client physics, so it copies the client: any move_player for its
// own entity after the bed click counts as a bed teleport, and the bot answers
// it the way the client does, with player_action stop_sleeping (Geyser sends
// that to Java as LEAVE_BED). Set EMULATE_WAKE=0 to only record the teleport.
// Talks to checks/bug3.sh through files in BUG3_DIR:
//   bot writes   pos     "X Y Z" of its feet, as Geyser placed it
//   shell writes go      "FX FY FZ" of the bed foot, after placing the bed
//   bot writes   used    after it sent the click
//   shell writes stop    when the hold is over and the bed was read
// Exit 0: ran to the end (the shell decides PASS or FAIL). Exit 3: bot-side
// precondition failed. Exit 1: kick, error or timeout.
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const dir = process.env.BUG3_DIR
const goTimeout = Number(process.env.GO_TIMEOUT_SECS || 120)
const stopTimeout = Number(process.env.STOP_TIMEOUT_SECS || 120)
const emulateWake = process.env.EMULATE_WAKE !== '0'
const EYE = 1.62
const BED_HEIGHT = 0.5625

if (!dir || !(goTimeout > 0) || !(stopTimeout > 0)) {
  console.log(`bug3-bot ${name}: FAIL bad BUG3_DIR, GO_TIMEOUT_SECS or STOP_TIMEOUT_SECS`)
  process.exit(2)
}

let done = false
function finish (code, why) {
  if (done) return
  done = true
  console.log(`bug3-bot ${name}: ${code === 0 ? 'DONE' : code === 3 ? 'PRECONDITION' : 'FAIL'} ${why}`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}
const log = (msg) => console.log(`bug3-bot ${name}: ${msg}`)
const fmt = (v) => `${v.x.toFixed(3)} ${v.y.toFixed(3)} ${v.z.toFixed(3)}`

const client = bedrock.createClient({
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51'
})

const self = (id) => client.entityId !== undefined && BigInt(id) === BigInt(client.entityId)
const invSlots = new Map() // player inventory slot -> item, as Geyser sent it
let pos = null // Bedrock (eye level) position Geyser last sent for us
let foot = null
let footRuntimeId = null
let clickedAt = 0 // ms timestamp of the bed click, 0 before it
let teleports = 0 // move_player for us after the click
let wakesSent = 0
let sleepSeen = false // Geyser told us we are sleeping (after the click)
let bedPosSeen = null

client.on('start_game', (p) => { pos = p.player_position })
client.on('inventory_content', (p) => {
  if (p.window_id === 'inventory') p.input.forEach((item, i) => invSlots.set(i, item))
})
client.on('inventory_slot', (p) => {
  if (p.window_id === 'inventory') invSlots.set(p.slot, p.item)
})
client.on('update_block', (p) => {
  if (foot && p.layer === 0 && p.position.x === foot.x && p.position.y === foot.y && p.position.z === foot.z) {
    footRuntimeId = p.block_runtime_id
  }
})

client.on('move_player', (p) => {
  if (!self(p.runtime_id)) return
  if (!clickedAt) { pos = p.position; return }
  teleports++
  const ms = Date.now() - clickedAt
  log(`BEDTELEPORT move_player for self ${ms} ms after the click: mode=${p.mode} pos ${fmt(p.position)} sleep_seen=${sleepSeen}`)
  if (emulateWake) {
    // What the Bedrock client does when it is teleported out of its bed.
    client.write('player_action', {
      runtime_entity_id: client.entityId,
      action: 'stop_sleeping',
      position: { x: 0, y: 0, z: 0 },
      result_position: { x: 0, y: 0, z: 0 },
      face: 0
    })
    wakesSent++
    log('sent player_action stop_sleeping (client wake emulation)')
  }
})

client.on('set_entity_data', (p) => {
  if (!self(p.runtime_entity_id)) return
  for (const m of p.metadata || []) {
    let what = null
    if (m.key === 'player_flags') what = `player_flags=${m.value}`
    else if (m.key === 'player_bed_position') what = `player_bed_position=${m.value.x},${m.value.y},${m.value.z}`
    else if (m.key === 'flags_extended' && m.value && typeof m.value === 'object') what = `flags_extended.sleeping=${m.value.sleeping}`
    if (!what) continue
    const sleeping = (m.key === 'player_flags' && (Number(m.value) & 2) === 2) ||
      (m.key === 'flags_extended' && m.value.sleeping === true)
    if (m.key === 'player_bed_position') bedPosSeen = m.value
    if (clickedAt && sleeping) sleepSeen = true
    log(`set_entity_data self ${what} ${clickedAt ? `${Date.now() - clickedAt} ms after the click` : 'before the click'}`)
  }
})

client.on('text', (p) => {
  // Server messages like "You can sleep only at night" explain a refused bed.
  log(`text type=${p.type} ${JSON.stringify(p.message)} ${JSON.stringify(p.parameters || [])}`)
})

const spawnTimer = setTimeout(() => finish(1, 'no spawn within 120 s'), 120 * 1000)

client.on('spawn', () => {
  clearTimeout(spawnTimer)
  // Let Geyser's spawn position settle before reporting it.
  setTimeout(reportPos, 3000)
})

function reportPos () {
  if (!pos) return finish(3, 'no position from start_game or move_player')
  const feet = { x: pos.x, y: Math.round((pos.y - EYE) * 1000) / 1000, z: pos.z }
  log(`pos eye ${fmt(pos)} feet ${fmt(feet)}`)
  fs.writeFileSync(path.join(dir, 'pos'), `${feet.x} ${feet.y} ${feet.z}\n`)
  const deadline = Date.now() + goTimeout * 1000
  const poll = setInterval(() => {
    const go = path.join(dir, 'go')
    if (fs.existsSync(go)) {
      clearInterval(poll)
      const [x, y, z] = fs.readFileSync(go, 'utf8').trim().split(/\s+/).map(Number)
      foot = { x, y, z }
      // Give Geyser's update_block for the bed a moment to arrive.
      setTimeout(useBed, 1500)
    } else if (Date.now() > deadline) {
      clearInterval(poll)
      finish(1, `no go file within ${goTimeout} s`)
    }
  }, 200)
}

function useBed () {
  if (![foot.x, foot.y, foot.z].every(Number.isInteger)) return finish(3, 'go file holds no bed position')
  // held_item is a full ItemV4; reuse the slot Geyser sent (empty hand = air).
  const held = invSlots.get(0)
  if (!held) return finish(3, 'Geyser sent no hotbar slot 0 to copy into the click')
  log(`bed foot ${foot.x} ${foot.y} ${foot.z} runtime_id=${footRuntimeId} hand network_id=${held.network_id}`)
  if (footRuntimeId === null) log('note: no update_block for the bed foot reached the bot')
  const eye = pos
  const dx = foot.x + 0.5 - eye.x
  const dy = foot.y + BED_HEIGHT - eye.y
  const dz = foot.z + 0.5 - eye.z
  log(`eye to bed top ${Math.sqrt(dx * dx + dy * dy + dz * dz).toFixed(2)} blocks`)

  // A real client right-clicks the bed: item_use click_block on its top face.
  client.write('inventory_transaction', {
    transaction: {
      legacy: { legacy_request_id: 0 },
      transaction_type: 'item_use',
      actions: [],
      transaction_data: {
        action_type: 'click_block',
        trigger_type: 'player_input',
        block_position: { x: foot.x, y: foot.y, z: foot.z },
        face: 1, // up
        hotbar_slot: 0,
        hand: 'main_hand',
        held_item: held,
        player_pos: { x: eye.x, y: eye.y, z: eye.z },
        click_pos: { x: 0.5, y: BED_HEIGHT, z: 0.5 },
        block_runtime_id: footRuntimeId === null ? 0 : footRuntimeId,
        client_prediction: 'success',
        client_cooldown_state: 'off'
      }
    }
  })
  clickedAt = Date.now()
  log(`sent item_use click_block on the bed foot, emulate_wake=${emulateWake}`)
  fs.writeFileSync(path.join(dir, 'used'), 'used\n')

  const deadline = Date.now() + stopTimeout * 1000
  const poll = setInterval(() => {
    if (fs.existsSync(path.join(dir, 'stop'))) {
      clearInterval(poll)
      const bed = bedPosSeen ? `${bedPosSeen.x},${bedPosSeen.y},${bedPosSeen.z}` : 'none'
      const summary = `RESULT teleports_after_click=${teleports} wakes_sent=${wakesSent} sleep_seen=${sleepSeen} bed_position=${bed}`
      if (!sleepSeen) return finish(3, `${summary}: Geyser never marked the bot as sleeping`)
      finish(0, summary)
    } else if (Date.now() > deadline) {
      clearInterval(poll)
      finish(1, `no stop file within ${stopTimeout} s`)
    }
  }, 200)
}

client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
