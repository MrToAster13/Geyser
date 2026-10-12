// Bug 4 bot: watches one pig the way a Bedrock 1.26.51 client sees it and
// rebuilds its position from add_entity, move_entity_delta and move_entity.
// Paper 26.3 sends stepped move packets. If Geyser keeps only part of the
// steps, the rebuilt position falls behind the server and later jumps when a
// position sync (move_entity) arrives.
// Talks to checks/bug4.sh through files in BUG4_DIR. The shell writes a file,
// the bot reads it and answers with <name>_ok:
//   bot writes   pos          "X Y Z" block the bot stands in
//   shell writes spawn        "x y z" where it summons the pig
//   bot writes   pig          "runtime_id x y z" from add_entity
//   shell writes base         "x y z" server Pos at rest -> Bedrock offset
//   shell writes slide        before it pushes the pig along the ground
//   shell writes probe_slide  "x y z" server Pos after the slide stopped
//   shell writes tp           "x y z" before it teleports the pig up to fall
//   shell writes probe_fall   "x y z" server Pos after the pig landed
//   shell writes end          -> bot writes result and exits
// result is "PASS ...", "FAIL ..." or "PRECONDITION ...".
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const dir = process.env.BUG4_DIR
const EYE = 1.62
// Largest allowed gap, in blocks, between the position Geyser gave the
// Bedrock client and the server's position or the next sync.
const LIMIT = Number(process.env.BUG4_LIMIT || 0.5)
const STEP_TIMEOUT = 90 * 1000

if (!dir || !(LIMIT > 0)) {
  console.log(`bug4-bot ${name}: FAIL bad BUG4_DIR or BUG4_LIMIT`)
  process.exit(2)
}

const t0 = Date.now()
const log = (msg) => console.log(`bug4-bot ${name}: +${Date.now() - t0}ms ${msg}`)
const f3 = (v) => (v === undefined || v === null ? 'none' : Number(v).toFixed(3))
const fv = (p) => `${f3(p.x)} ${f3(p.y)} ${f3(p.z)}`
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z)

let done = false
function writeResult (line) {
  try { fs.writeFileSync(path.join(dir, 'result'), line + '\n') } catch (e) {}
}
function finish (code, why) {
  if (done) return
  done = true
  const word = code === 0 ? 'DONE' : code === 3 ? 'PRECONDITION' : 'FAIL'
  console.log(`bug4-bot ${name}: ${word} ${why}`)
  if (code !== 0 && !fs.existsSync(path.join(dir, 'result'))) {
    writeResult(`${code === 3 ? 'PRECONDITION' : 'ERROR'} ${why}`)
  }
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

let self = null // our eye-level position from start_game or move_player
const pigs = new Map() // runtime id -> rebuilt Bedrock position of every pig
let pigId = null // runtime id of the summoned pig
let pigAdds = 0

// Measurement state for the current phase.
let phase = 'setup'
const stats = {} // phase -> { delta, abs, maxSnap, snapAt }
let tpTarget = null // Bedrock position the tp should reach; snaps wait for it
let offset = null // Bedrock position minus server position at rest

function phaseStats () {
  if (!stats[phase]) stats[phase] = { delta: 0, abs: 0, maxSnap: 0, snapAt: '' }
  return stats[phase]
}

const key = (id) => BigInt(id).toString()

client.on('start_game', (p) => { self = p.player_position })
client.on('move_player', (p) => {
  if (client.entityId !== undefined && key(p.runtime_id) === key(client.entityId)) self = p.position
})

client.on('add_entity', (p) => {
  if (p.entity_type !== 'minecraft:pig') return
  const id = key(p.runtime_id)
  pigs.set(id, { x: p.position.x, y: p.position.y, z: p.position.z })
  pigAdds++
  log(`add_entity pig runtime_id=${id} at ${fv(p.position)}`)
})

function onPigMove (id, kind, next, p) {
  if (id !== pigId) return
  const prev = pigs.get(id)
  const s = phaseStats()
  let note = ''
  if (kind === 'abs') {
    s.abs++
    // How far the sync moved the pig from where the deltas had put it.
    const snap = dist(prev, next)
    if (tpTarget) {
      note = ` gap=${snap.toFixed(3)} (before tp arrived, not counted)`
    } else {
      note = ` snap=${snap.toFixed(3)}`
      if (snap > s.maxSnap) { s.maxSnap = snap; s.snapAt = `from ${fv(prev)} to ${fv(next)}` }
    }
  } else {
    s.delta++
  }
  pigs.set(id, next)
  if (tpTarget && Math.abs(next.y - tpTarget.y) < 1.5 &&
      Math.hypot(next.x - tpTarget.x, next.z - tpTarget.z) < 1.5) {
    note += ' (tp arrived)'
    tpTarget = null
  }
  log(`${phase} ${kind === 'abs' ? 'move_entity' : 'move_entity_delta'} ${fv(next)}${note}` +
    (kind === 'abs' ? '' : ` on_ground=${p.on_ground} ticks=${p.ticks}`))
}

client.on('move_entity_delta', (p) => {
  const id = key(p.runtime_entity_id)
  const prev = pigs.get(id)
  if (!prev) return
  // Each axis is optional and holds the absolute position when present.
  const next = {
    x: p.x !== undefined && p.x !== null ? p.x : prev.x,
    y: p.y !== undefined && p.y !== null ? p.y : prev.y,
    z: p.z !== undefined && p.z !== null ? p.z : prev.z
  }
  if (id === pigId) {
    if (next.x === prev.x && next.y === prev.y && next.z === prev.z) return // rotation only
    onPigMove(id, 'delta', next, p)
  } else {
    pigs.set(id, next)
  }
})

client.on('move_entity', (p) => {
  const id = key(p.runtime_entity_id)
  if (!pigs.has(id)) return
  const next = { x: p.position.x, y: p.position.y, z: p.position.z }
  if (id === pigId) onPigMove(id, 'abs', next, p)
  else pigs.set(id, next)
})

client.on('remove_entity', (p) => {
  if (pigId !== null && pigs.has(pigId)) log(`remove_entity unique_id=${p.entity_id_self}`)
})

function waitFile (file, timeout = STEP_TIMEOUT) {
  const full = path.join(dir, file)
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeout
    const poll = setInterval(() => {
      if (fs.existsSync(full)) {
        clearInterval(poll)
        resolve(fs.readFileSync(full, 'utf8').trim())
      } else if (done || Date.now() > deadline) {
        clearInterval(poll)
        reject(new Error(`no ${file} file within ${timeout / 1000} s`))
      }
    }, 50)
  })
}
const ack = (file) => fs.writeFileSync(path.join(dir, `${file}_ok`), 'ok\n')
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
function parseVec (text) {
  const [x, y, z] = text.split(/\s+/).map(Number)
  if (![x, y, z].every(Number.isFinite)) throw new Error(`bad position '${text}'`)
  return { x, y, z }
}

// Rebuilt pig position minus the offset, against the server's Pos.
function drift (truth) {
  const p = pigs.get(pigId)
  const shown = { x: p.x - offset.x, y: p.y - offset.y, z: p.z - offset.z }
  return { d: dist(shown, truth), shown }
}

const spawnTimer = setTimeout(() => finish(1, 'no spawn within 120 s'), 120 * 1000)
client.on('spawn', () => {
  clearTimeout(spawnTimer)
  setTimeout(() => run().catch((e) => finish(1, e.message)), 3000)
})

async function run () {
  if (!self) return finish(3, 'no position from start_game or move_player')
  const feet = { x: Math.floor(self.x), y: Math.floor(Math.round((self.y - EYE) * 1000) / 1000), z: Math.floor(self.z) }
  log(`self ${fv(self)} feet block ${feet.x} ${feet.y} ${feet.z}`)
  fs.writeFileSync(path.join(dir, 'pos'), `${feet.x} ${feet.y} ${feet.z}\n`)

  // Find the summoned pig: the add_entity nearest the spawn spot.
  const spot = parseVec(await waitFile('spawn'))
  ack('spawn')
  const deadline = Date.now() + 15000
  while (pigId === null && Date.now() < deadline) {
    for (const [id, p] of pigs) {
      if (Math.hypot(p.x - spot.x, p.z - spot.z) < 1.5 && Math.abs(p.y - spot.y) < 2) pigId = id
    }
    if (pigId === null) await sleep(100)
  }
  if (pigId === null) {
    return finish(3, `no add_entity for a pig near ${fv(spot)} within 15 s (pig add_entity seen: ${pigAdds})`)
  }
  const pig0 = pigs.get(pigId)
  log(`precondition: add_entity for the summoned pig runtime_id=${pigId} at ${fv(pig0)}`)
  fs.writeFileSync(path.join(dir, 'pig'), `${pigId} ${fv(pig0)}\n`)

  // Baseline at rest gives the Bedrock offset for this entity type.
  const base = parseVec(await waitFile('base'))
  const restPos = pigs.get(pigId)
  offset = { x: restPos.x - base.x, y: restPos.y - base.y, z: restPos.z - base.z }
  log(`baseline: Bedrock ${fv(restPos)} server ${fv(base)} offset ${fv(offset)}`)
  ack('base')
  if (Math.hypot(offset.x, offset.y, offset.z) > 1) {
    return finish(3, `pig at rest is ${fv(offset)} from the server position; baseline unusable`)
  }

  // Slide: on the ground the pig keeps onGround, so the server sends only
  // move packets and no position sync for 400 ticks. What Geyser drops stays.
  phase = 'slide'
  await waitFile('slide')
  ack('slide')
  const truthSlide = parseVec(await waitFile('probe_slide'))
  await sleep(300)
  const ds = drift(truthSlide)
  log(`slide end: Bedrock shows ${fv(ds.shown)} server ${fv(truthSlide)} drift=${ds.d.toFixed(3)}`)
  ack('probe_slide')

  // Fall: the tp jump is not counted; every sync after it is.
  phase = 'fall'
  const tp = parseVec(await waitFile('tp'))
  tpTarget = { x: tp.x + offset.x, y: tp.y + offset.y, z: tp.z + offset.z }
  ack('tp')
  const truthFall = parseVec(await waitFile('probe_fall'))
  await sleep(300)
  const df = drift(truthFall)
  log(`fall end: Bedrock shows ${fv(df.shown)} server ${fv(truthFall)} drift=${df.d.toFixed(3)}`)
  ack('probe_fall')
  const tpSeen = tpTarget === null

  await waitFile('end')
  const sl = stats.slide || { delta: 0, abs: 0, maxSnap: 0, snapAt: '' }
  const fa = stats.fall || { delta: 0, abs: 0, maxSnap: 0, snapAt: '' }
  log(`slide packets: move_entity_delta=${sl.delta} move_entity=${sl.abs} max_snap=${sl.maxSnap.toFixed(3)} ${sl.snapAt}`)
  log(`fall packets: move_entity_delta=${fa.delta} move_entity=${fa.abs} max_snap=${fa.maxSnap.toFixed(3)} ${fa.snapAt}`)

  // Bot-side preconditions (R2-e): Geyser forwarded movement in both phases.
  const why = []
  if (sl.delta + sl.abs === 0) why.push('no pig move packet during the slide')
  if (!tpSeen) why.push('the tp never reached the Bedrock client')
  if (fa.delta + fa.abs === 0) why.push('no pig move packet during the fall')
  if (why.length) {
    writeResult(`PRECONDITION ${why.join('; ')}`)
    ack('end')
    return finish(3, why.join('; '))
  }

  const metrics = `slide_drift=${ds.d.toFixed(3)} fall_drift=${df.d.toFixed(3)} ` +
    `slide_max_snap=${sl.maxSnap.toFixed(3)} fall_max_snap=${fa.maxSnap.toFixed(3)} ` +
    `slide_packets=${sl.delta}+${sl.abs} fall_packets=${fa.delta}+${fa.abs} limit=${LIMIT}`
  const bad = ds.d > LIMIT || df.d > LIMIT || sl.maxSnap > LIMIT || fa.maxSnap > LIMIT
  writeResult(`${bad ? 'FAIL' : 'PASS'} ${metrics}`)
  ack('end')
  finish(0, metrics)
}

client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
