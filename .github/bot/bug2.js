// Bug 2 bot: records the crafting recipes Geyser sends a Bedrock 1.26.51 client.
// Keeps every crafting_data packet from login onward and empties the set when a
// packet arrives with clear_recipes true (R6-d, R7-f). Output item network ids
// map to names through the item_registry packet (R4-a).
// Talks to checks/bug2.sh through files in BUG2_DIR:
//   bot writes   spawned   after spawn
//   shell writes given     after the `recipe give` result line
//   bot writes   bot.json  the final recipe set, the item registry and timings
// The bot finishes QUIET_SECS after the later of `given` and the last
// crafting_data, at most MAX_AFTER_SECS after `given`.
// Exit 0: bot.json written. Exit 3: a bot-side precondition failed.
// Exit 1: kick, disconnect or timeout.
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const dir = process.env.BUG2_DIR
const quietSecs = Number(process.env.QUIET_SECS || 10)
const maxAfterSecs = Number(process.env.MAX_AFTER_SECS || 90)
const givenTimeout = Number(process.env.GIVEN_TIMEOUT_SECS || 180)

if (!dir || !(quietSecs > 0) || !(maxAfterSecs > 0) || !(givenTimeout > 0)) {
  console.log(`bug2-bot ${name}: FAIL bad BUG2_DIR, QUIET_SECS, MAX_AFTER_SECS or GIVEN_TIMEOUT_SECS`)
  process.exit(2)
}

const t0 = Date.now()
const ms = () => Date.now() - t0
const log = (msg) => console.log(`bug2-bot ${name}: [${ms()} ms] ${msg}`)

let done = false
function finish (code, why) {
  if (done) return
  done = true
  console.log(`bug2-bot ${name}: ${code === 0 ? 'DONE' : code === 3 ? 'PRECONDITION' : 'FAIL'} ${why}`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}

const client = bedrock.createClient({
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51'
})

// Record which packet ids fail to parse, so a minecraft-data gap in
// crafting_data is told apart from a Geyser failure.
const parseErrors = []
const origParse = client.deserializer.parsePacketBuffer.bind(client.deserializer)
client.deserializer.parsePacketBuffer = (buf) => {
  try {
    return origParse(buf)
  } catch (e) {
    let id = 0; let shift = 0
    for (let i = 0; i < 5 && i < buf.length; i++) {
      id |= (buf[i] & 0x7f) << shift
      shift += 7
      if (!(buf[i] & 0x80)) break
    }
    parseErrors.push({ id: id & 0x3ff, len: buf.length, msg: String(e && e.message).slice(0, 300) })
    throw e
  }
}

const items = new Map() // network id -> name
let itemRegistryAt = null
function onItems (states, from) {
  if (!states || !states.length) return
  for (const s of states) items.set(s.runtime_id, s.name)
  itemRegistryAt = ms()
  log(`${from}: ${states.length} item states`)
}
client.on('item_registry', (p) => onItems(p.itemstates, 'item_registry'))
client.on('start_game', (p) => onItems(p.itemstates, 'start_game'))

const sizes = []
client.on('packet', (des) => {
  if (des.data && des.data.name === 'crafting_data') sizes.push(des.fullBuffer ? des.fullBuffer.length : -1)
})

function descriptor (ing) {
  if (!ing || ing.type !== 'valid') return { t: 'empty', count: ing ? ing.count : 0 }
  switch (ing.descriptor_type) {
    case 'name': return { t: 'name', name: ing.name, meta: ing.metadata, count: ing.count }
    case 'item_tag': return { t: 'tag', tag: ing.tag, count: ing.count }
    case 'empty': return { t: 'empty', count: ing.count }
    default: return { t: String(ing.descriptor_type), raw: JSON.stringify(ing).slice(0, 200), count: ing.count }
  }
}
function output (o) {
  return { id: o.network_id, name: items.get(o.network_id) || null, count: o.count, meta: o.metadata }
}

let recipes = [] // final set since the last clear_recipes
const packets = [] // one summary per crafting_data
let lastCraftingAt = null
client.on('crafting_data', (p) => {
  if (p.clear_recipes) recipes = []
  for (const r of p.shaped_recipes || []) {
    recipes.push({ kind: 'shaped', id: r.recipe_id, block: r.block, w: r.width, h: r.height, in: r.input.map(descriptor), out: (r.output || []).map(output) })
  }
  for (const r of p.shapeless_recipes || []) {
    recipes.push({ kind: 'shapeless', id: r.recipe_id, block: r.block, in: r.input.map(descriptor), out: (r.output || []).map(output) })
  }
  lastCraftingAt = ms()
  const s = { at: lastCraftingAt, clear: p.clear_recipes, shaped: (p.shaped_recipes || []).length, shapeless: (p.shapeless_recipes || []).length, multi: (p.multi_recipes || []).length, afterGiven: givenAt !== null }
  packets.push(s)
  log(`crafting_data ${JSON.stringify(s)} set=${recipes.length}`)
})

let spawnedAt = null
let givenAt = null
const spawnTimer = setTimeout(() => finish(1, 'no spawn within 120 s'), 120 * 1000)

function writeOut (why) {
  const out = {
    spawnedAt, itemRegistryAt, givenAt, lastCraftingAt, endAt: ms(),
    packets, sizes, parseErrors,
    items: Object.fromEntries(items),
    recipes
  }
  fs.writeFileSync(path.join(dir, 'bot.json'), JSON.stringify(out))
  log(`wrote bot.json: ${recipes.length} recipes, ${items.size} items, ${packets.length} crafting_data packets (${why})`)
}

client.on('spawn', () => {
  clearTimeout(spawnTimer)
  spawnedAt = ms()
  log('spawned')
  fs.writeFileSync(path.join(dir, 'spawned'), String(spawnedAt))
  const waitGiven = setInterval(() => {
    if (fs.existsSync(path.join(dir, 'given'))) {
      clearInterval(waitGiven)
      givenAt = ms()
      log('given seen')
      const tick = setInterval(() => {
        const since = Math.max(givenAt, lastCraftingAt || 0)
        const quiet = ms() - since >= quietSecs * 1000
        const cap = ms() - givenAt >= maxAfterSecs * 1000
        if (quiet || cap) {
          clearInterval(tick)
          writeOut(quiet ? `quiet ${quietSecs} s` : `cap ${maxAfterSecs} s`)
          if (!items.size) return finish(3, 'no item registry received')
          if (!packets.length) return finish(3, 'no crafting_data received')
          if (parseErrors.some((e) => e.id === 0x34)) return finish(3, 'a crafting_data packet failed to parse')
          finish(0, 'recorded')
        }
      }, 250)
    } else if (ms() - spawnedAt > givenTimeout * 1000) {
      clearInterval(waitGiven)
      finish(1, `no given file within ${givenTimeout} s`)
    }
  }, 250)
})
client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
// Parse errors arrive here too; they are recorded above and judged at the end.
client.on('error', (e) => log(`error: ${e && e.message ? e.message.slice(0, 300) : e}`))
