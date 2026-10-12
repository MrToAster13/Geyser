// Bug 6 bot: joins, records every entity packet that can carry a Bedrock name tag,
// waits for the shell to summon the cushions, then counts name tags per cushion.
// Exit codes: 0 PASS, 1 FAIL, 3 precondition not met, 4 bot connection failure.
//
// Env:
//   BOT_NAME        bot username (default Bot6)
//   BUG6_DIR        directory the shell writes "done" into when the summons have settled
//   BUG6_PLAIN      plain cushion spots, "x,y,z;x,y,z" (no custom name: Java shows no name tag)
//   BUG6_CONTROL    control cushion spot "x,y,z" (custom name BUG6_PROBE, shown: one name tag)
//   BUG6_PROBE      control custom name (default bug6probe)
//   BUG6_TIMEOUT    seconds to wait for "done" after spawn (default 240)
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot6'
const dir = process.env.BUG6_DIR
const probe = process.env.BUG6_PROBE || 'bug6probe'
const timeout = Number(process.env.BUG6_TIMEOUT || 240)
const parseSpot = (s) => {
  const v = s.split(',').map(Number)
  if (v.length !== 3 || v.some((n) => !Number.isFinite(n))) throw new Error(`bad spot ${s}`)
  return { x: v[0], y: v[1], z: v[2] }
}
let plain, control
try {
  if (!dir) throw new Error('BUG6_DIR unset')
  plain = (process.env.BUG6_PLAIN || '').split(';').filter(Boolean).map(parseSpot)
  control = parseSpot(process.env.BUG6_CONTROL || '')
  if (plain.length === 0) throw new Error('BUG6_PLAIN empty')
} catch (e) {
  console.log(`bug6 bot: PRECONDITION bad env: ${e.message}`)
  process.exit(3)
}

// A cushion matches a spot when its spawn position is within this horizontal
// distance of the summon point. An entity counts toward a spot's name tags when
// it spawns within NEAR horizontally and DY vertically (a floating tag sits above).
const MATCH = 0.75
const NEAR = 1.5
const DY = 3

const ents = new Map() // runtime id -> { type, pos, packet, alive, names: [], tagPackets }
let ownRid = null
let spawned = false

const key = (id) => String(id)
function nameOf (metadata) {
  if (!Array.isArray(metadata)) return null
  const m = metadata.find((e) => e.key === 'nametag')
  return m ? String(m.value) : null
}
function alwaysOf (metadata) {
  if (!Array.isArray(metadata)) return null
  const m = metadata.find((e) => e.key === 'always_show_nametag')
  return m ? Number(m.value) : null
}
function record (pkt, rid, type, pos, metadata) {
  const id = key(rid)
  const e = { type, pos, packet: pkt, alive: true, names: [], tagPackets: 0 }
  ents.set(id, e)
  note(id, pkt, metadata)
  console.log(`pkt ${pkt} rid=${id} type=${type} pos=${fmt(pos)} name=${JSON.stringify(nameOf(metadata))} always=${alwaysOf(metadata)}`)
}
function note (id, pkt, metadata) {
  const e = ents.get(id)
  const n = nameOf(metadata)
  if (!e || n === null) return
  e.names.push(n)
  if (n.length > 0) e.tagPackets++
}
const fmt = (p) => p ? `${p.x.toFixed(2)},${p.y.toFixed(2)},${p.z.toFixed(2)}` : '?'
const hdist = (a, b) => Math.hypot(a.x - b.x, a.z - b.z)

const client = bedrock.createClient({
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51'
})

let done = false
function finish (code, why) {
  if (done) return
  done = true
  console.log(`bug6 bot: ${['PASS', 'FAIL', '', 'PRECONDITION', 'BOTFAIL'][code] || code} ${why}`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}

client.on('start_game', (p) => { ownRid = key(p.runtime_entity_id) })
client.on('add_entity', (p) => record('add_entity', p.runtime_id, p.entity_type, p.position, p.metadata))
client.on('add_item_entity', (p) => record('add_item_entity', p.runtime_entity_id, 'item', p.position, p.metadata))
client.on('add_player', (p) => record('add_player', p.runtime_id, `player:${p.username}`, p.position, p.metadata))
client.on('set_entity_data', (p) => {
  const id = key(p.runtime_entity_id)
  const n = nameOf(p.metadata)
  if (n !== null) console.log(`pkt set_entity_data rid=${id} name=${JSON.stringify(n)} always=${alwaysOf(p.metadata)}`)
  note(id, 'set_entity_data', p.metadata)
})
client.on('remove_entity', (p) => {
  const id = key(p.entity_id_self)
  const e = ents.get(id)
  if (e) { e.alive = false; console.log(`pkt remove_entity rid=${id} type=${e.type}`) }
})

// Name tags around one spot. Returns { cushions, carriers } over entities still alive.
function around (spot) {
  const cushions = []
  const carriers = []
  for (const [id, e] of ents) {
    if (!e.alive || id === ownRid || !e.pos) continue
    if (/cushion/.test(e.type) && hdist(e.pos, spot) <= MATCH) cushions.push(id)
    if (hdist(e.pos, spot) <= NEAR && Math.abs(e.pos.y - spot.y) <= DY && e.tagPackets > 0) carriers.push(id)
  }
  return { cushions, carriers }
}
const describe = (ids) => ids.map((id) => {
  const e = ents.get(id)
  return `rid=${id} type=${e.type} pos=${fmt(e.pos)} names=${JSON.stringify([...new Set(e.names)])} tagPackets=${e.tagPackets}`
}).join('; ') || 'none'

function evaluate () {
  const all = [...ents.values()].filter((e) => /cushion/.test(e.type))
  console.log(`cushion add_entity packets seen: ${all.length}`)
  const fails = []
  const missing = []

  // Control first: proves the bot sees a cushion name tag when Java shows one.
  const c = around(control)
  console.log(`control ${fmt(control)}: cushions=[${describe(c.cushions)}] tagCarriers=[${describe(c.carriers)}]`)
  if (c.cushions.length === 0) missing.push(`no add_entity for the control cushion at ${fmt(control)}`)
  else if (!c.carriers.some((id) => ents.get(id).names.some((n) => n.includes(probe)))) {
    missing.push(`control cushion never carried the name "${probe}", so the detector is blind`)
  }
  if (c.carriers.length > 1) fails.push(`control: ${c.carriers.length} name tags for one named cushion (Java shows 1)`)
  if (c.cushions.length > 1) fails.push(`control: ${c.cushions.length} cushion entities for one Java cushion`)

  plain.forEach((spot, i) => {
    const r = around(spot)
    console.log(`plain${i + 1} ${fmt(spot)}: cushions=[${describe(r.cushions)}] tagCarriers=[${describe(r.carriers)}]`)
    if (r.cushions.length === 0) { missing.push(`no add_entity for plain cushion ${i + 1} at ${fmt(spot)}`); return }
    if (r.carriers.length > 0) fails.push(`plain${i + 1}: ${r.carriers.length} name tag(s) on an unnamed cushion (Java shows 0)`)
    if (r.cushions.length > 1) fails.push(`plain${i + 1}: ${r.cushions.length} cushion entities for one Java cushion`)
  })

  // A failure is only reported once every cushion's add_entity arrived (R2-e).
  if (missing.length) return finish(3, missing.join('; '))
  if (fails.length) return finish(1, fails.join('; '))
  finish(0, `${plain.length} unnamed cushion(s) carry no name tag; control carries exactly one`)
}

const spawnTimer = setTimeout(() => finish(4, 'no spawn within 120 s'), 120000)
client.on('spawn', () => {
  clearTimeout(spawnTimer)
  spawned = true
  console.log(`bug6 bot: spawned (own rid ${ownRid})`)
  const start = Date.now()
  const poll = setInterval(() => {
    if (fs.existsSync(path.join(dir, 'done'))) { clearInterval(poll); evaluate() } else if (Date.now() - start > timeout * 1000) {
      clearInterval(poll); finish(3, `no done file within ${timeout} s`)
    }
  }, 200)
})
const lost = (why) => finish(spawned ? 3 : 4, why)
client.on('kick', (p) => lost(`kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => lost(`disconnected: ${JSON.stringify(p)}`))
client.on('close', () => lost('connection closed'))
client.on('error', (e) => lost(`error: ${e && e.stack ? e.stack : e}`))
