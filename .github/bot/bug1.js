// Bug 1 bot: uses an iron hoe on the top face of a grass block, the way a
// Bedrock 1.26.51 client does (inventory_transaction, item_use, click_block).
// Talks to checks/bug1.sh through files in BUG1_DIR:
//   bot writes  target  "X Y Z" of the block to till, picked next to its feet
//   shell writes go      after it placed the block and gave the hoe
//   bot writes  used     after it sent the click
// Exit 0: click sent. Exit 3: a precondition failed. Exit 1: kick, error, timeout.
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const dir = process.env.BUG1_DIR
const goTimeout = Number(process.env.GO_TIMEOUT_SECS || 120)
const afterSecs = Number(process.env.AFTER_SECS || 8)
const HOE = 'minecraft:iron_hoe'
const EYE = 1.62
// Geyser's limit is block_interaction_range + 1 from the eye to the block box;
// stay well inside the vanilla 4.5 so reach never decides the result.
const MAX_REACH = 4.5

if (!dir || !(goTimeout > 0) || !(afterSecs > 0)) {
  console.log(`bug1-bot ${name}: FAIL bad BUG1_DIR, GO_TIMEOUT_SECS or AFTER_SECS`)
  process.exit(2)
}

let done = false
function finish (code, why) {
  if (done) return
  done = true
  console.log(`bug1-bot ${name}: ${code === 0 ? 'DONE' : code === 3 ? 'PRECONDITION' : 'FAIL'} ${why}`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}
const log = (msg) => console.log(`bug1-bot ${name}: ${msg}`)

const client = bedrock.createClient({
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51'
})

const itemIds = new Map() // item name -> network id, from item_registry
const invSlots = new Map() // player inventory slot -> ItemV4, as Geyser sent it
let pos = null // Bedrock (eye level) position Geyser last sent for us
let target = null
const blockUpdates = [] // update_block packets for the target, in order
let used = false

function onItems (states) {
  for (const s of states || []) itemIds.set(s.name, s.runtime_id)
}
client.on('item_registry', (p) => onItems(p.itemstates))
client.on('start_game', (p) => {
  onItems(p.itemstates)
  pos = p.player_position
})
client.on('move_player', (p) => {
  if (client.startGameData && BigInt(p.runtime_id) === BigInt(client.entityId)) pos = p.position
})
client.on('inventory_content', (p) => {
  if (p.window_id !== 'inventory') return
  p.input.forEach((item, i) => invSlots.set(i, item))
})
client.on('inventory_slot', (p) => {
  if (p.window_id === 'inventory') invSlots.set(p.slot, p.item)
})
client.on('update_block', (p) => {
  if (!target) return
  const b = p.position
  if (b.x === target.x && b.y === target.y && b.z === target.z && p.layer === 0) {
    blockUpdates.push(p.block_runtime_id)
    log(`update_block at target runtime_id=${p.block_runtime_id} after_click=${used}`)
  }
})

const spawnTimer = setTimeout(() => finish(1, 'no spawn within 120 s'), 120 * 1000)

client.on('spawn', () => {
  clearTimeout(spawnTimer)
  // Let Geyser's spawn position settle before picking the block.
  setTimeout(pickTarget, 3000)
})

function pickTarget () {
  if (!pos) return finish(3, 'no position from start_game or move_player')
  const feetY = Math.round((pos.y - EYE) * 1000) / 1000
  target = { x: Math.floor(pos.x) + 1, y: Math.floor(feetY) - 1, z: Math.floor(pos.z) }
  log(`pos ${pos.x.toFixed(3)} ${pos.y.toFixed(3)} ${pos.z.toFixed(3)} target ${target.x} ${target.y} ${target.z}`)
  fs.writeFileSync(path.join(dir, 'target'), `${target.x} ${target.y} ${target.z}\n`)
  const deadline = Date.now() + goTimeout * 1000
  const poll = setInterval(() => {
    if (fs.existsSync(path.join(dir, 'go'))) {
      clearInterval(poll)
      // Give Geyser's last inventory_slot and update_block a moment to arrive.
      setTimeout(useHoe, 1000)
    } else if (Date.now() > deadline) {
      clearInterval(poll)
      finish(1, `no go file within ${goTimeout} s`)
    }
  }, 200)
}

function useHoe () {
  // Preconditions, each from Geyser's side of the connection (R2-e).
  const hoeId = itemIds.get(HOE)
  if (hoeId === undefined) return finish(3, `${HOE} not in the item registry`)
  const slot0 = invSlots.get(0)
  if (!slot0 || slot0.network_id !== hoeId) {
    return finish(3, `hotbar slot 0 holds network_id=${slot0 ? slot0.network_id : 'none'}, want ${hoeId} (${HOE})`)
  }
  log(`precondition: hotbar slot 0 holds ${HOE} network_id=${hoeId} stack_id=${slot0.has_stack_id ? slot0.stack_id : 'none'}`)
  // Since protocol 975 a serverbound item has a variant varint before the
  // stack net id; bedrock-protocol's ItemV4 omits it, and Geyser kicks with
  // "Not oneOf<ItemStackNetId, ...>". Without a net id both layouts are the
  // same bytes. Geyser compares only the item definition for the held item.
  const held = { ...slot0, has_stack_id: false }
  delete held.stack_id
  if (blockUpdates.length === 0) return finish(3, 'Geyser sent no update_block for the target after setblock')
  const blockRuntimeId = blockUpdates[blockUpdates.length - 1]
  log(`precondition: Geyser's view of the target block runtime_id=${blockRuntimeId}`)
  const eye = pos
  const dx = target.x + 0.5 - eye.x
  const dy = target.y + 1 - eye.y
  const dz = target.z + 0.5 - eye.z
  const dist = Math.sqrt(dx * dx + dy * dy + dz * dz)
  if (!(dist < MAX_REACH)) return finish(3, `target ${dist.toFixed(2)} blocks from the eye, over ${MAX_REACH}`)
  log(`precondition: eye to top face center ${dist.toFixed(2)} blocks`)

  // A real client selects the slot with mob_equipment before it uses the item.
  client.write('mob_equipment', {
    runtime_entity_id: client.entityId,
    item: held,
    slot: 0,
    selected_slot: 0,
    window_id: 'inventory'
  })

  setTimeout(() => {
    client.write('inventory_transaction', {
      transaction: {
        legacy: { legacy_request_id: 0 },
        transaction_type: 'item_use',
        actions: [],
        transaction_data: {
          action_type: 'click_block',
          trigger_type: 'player_input',
          block_position: { x: target.x, y: target.y, z: target.z },
          face: 1, // up
          hotbar_slot: 0,
          hand: 'main_hand',
          held_item: held,
          player_pos: { x: eye.x, y: eye.y, z: eye.z },
          click_pos: { x: 0.5, y: 1, z: 0.5 },
          block_runtime_id: blockRuntimeId,
          client_prediction: 'success',
          client_cooldown_state: 'off'
        }
      }
    })
    used = true
    log(`sent item_use click_block at ${target.x} ${target.y} ${target.z} face up`)
    fs.writeFileSync(path.join(dir, 'used'), 'used\n')
    setTimeout(() => finish(0, `click sent, stayed ${afterSecs} s`), afterSecs * 1000)
  }, 500)
}

client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
