// Bug 4 crowd bot: watches a crowd of named mobs walking under their own AI
// the way a Bedrock 1.26.51 client sees them, and rebuilds every position
// from add_entity, move_entity_delta and move_entity.
// Paper 26.3 can send stepped move packets. Geyser applies only the last
// step (JavaMoveEntityPos*Translator) and adds it to the running position
// (LivingEntity.moveRelative), so a dropped step stays in the Bedrock
// position until the next EntityPositionSync replaces it.
// Talks to checks/bug4crowd.sh through files in BUG4_DIR. The shell writes a
// file, the bot reads it and answers with <name>_ok:
//   bot writes   pos     "X Y Z" block the bot stands in
//   shell writes wander  "<count>" mobs summoned; counting starts
//   shell writes settle  events are over and every mob has NoAI; the mobs
//                        settle unfrozen so pending lerps, knockback and
//                        falls finish
//   shell writes pre     "b4mN x y z" lines, server Pos just before the freeze
//   shell writes frozen  right after tick freeze
//   shell writes snap    0.5 s later; the bot snapshots every position
//   shell writes truth   "b4mN x y z" lines, the server Pos of every mob
//   shell writes end     -> bot writes result and exits
// result is "PASS ...", "FAIL ..." or "PRECONDITION ...".
// During the wander the shell sends random entity events and logs the ones
// that move a mob at once (tp, Motion, ride, dismount) to the kicks file as
// "b4mN epoch_ms". Mobs that ever ride another (set_entity_link) have their
// position set by the vehicle, so the verdict leaves them out and reports
// their drift on its own line.
// Geyser does not tick entity lerps while the server is frozen (neither does
// the Java client), so a mob still moving at the freeze shows lerp lag, not
// lasting error. The verdict leaves out every mob that moved on Bedrock in
// the last LATE_MS before the freeze or after it, or whose server Pos changed
// between the pre and truth reads, and reports those mobs on their own line.
const fs = require('fs')
const path = require('path')
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const dir = process.env.BUG4_DIR
const EYE = 1.62
// Largest allowed gap, in blocks, between a mob's Bedrock position and its
// server position once the server is frozen and Geyser's lerp has finished.
const LIMIT = Number(process.env.BUG4_LIMIT || 0.5)
const MIN_MOBS = 50
const STEP_TIMEOUT = 240 * 1000
const NAME_RE = /^b4m\d+$/
// A kick reaches Bedrock within: up to 1 tick until the server runs the
// console command, the 2 ticks the check asks for, and Geyser's 3-tick lerp.
const KICK_MS = 300
// A Bedrock move this close before the freeze, or any after it, marks a mob
// as still moving. Geyser's lerp sends one move per tick, so a lerp still in
// flight at the freeze leaves a move within about 50 ms of it.
const LATE_MS = 1000
// Server Pos change between the pre and truth reads that counts as moving.
const SERVER_EPS = 0.001

if (!dir || !(LIMIT > 0)) {
  console.log(`bug4crowd-bot ${name}: FAIL bad BUG4_DIR or BUG4_LIMIT`)
  process.exit(2)
}

const t0 = Date.now()
const log = (msg) => console.log(`bug4crowd-bot ${name}: +${Date.now() - t0}ms ${msg}`)
const f3 = (v) => (v === undefined || v === null ? 'none' : Number(v).toFixed(3))
const fv = (p) => `${f3(p.x)} ${f3(p.y)} ${f3(p.z)}`
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z)
const key = (id) => BigInt(id).toString()

let done = false
function writeResult (line) {
  try { fs.writeFileSync(path.join(dir, 'result'), line + '\n') } catch (e) {}
}
function finish (code, why) {
  if (done) return
  done = true
  const word = code === 0 ? 'DONE' : code === 3 ? 'PRECONDITION' : 'FAIL'
  console.log(`bug4crowd-bot ${name}: ${word} ${why}`)
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

let self = null
// runtime id -> { type, uid, name, pos, steps[{ s, t }], moves, abs, motion,
//   settleMoves, settleDist, lastSettleAt, post, postMoves, rode }
const ents = new Map()
const byUnique = new Map()
let phase = 'setup'
let removedNamed = 0
let motionPackets = 0
let linkPackets = 0
let tFreeze = 0

function nameFrom (metadata) {
  for (const m of metadata || []) {
    if (m && typeof m.value === 'string' && NAME_RE.test(m.value)) return m.value
  }
  return null
}

client.on('start_game', (p) => { self = p.player_position })
client.on('move_player', (p) => {
  if (client.entityId !== undefined && key(p.runtime_id) === key(client.entityId)) self = p.position
})

client.on('add_entity', (p) => {
  const id = key(p.runtime_id)
  const e = {
    type: String(p.entity_type || '?').replace(/^minecraft:/, ''),
    uid: key(p.unique_id),
    name: nameFrom(p.metadata),
    pos: { x: p.position.x, y: p.position.y, z: p.position.z },
    steps: [],
    moves: 0,
    abs: 0,
    motion: 0,
    settleMoves: 0,
    settleDist: 0,
    lastSettleAt: 0,
    post: 0,
    postMoves: 0,
    rode: false
  }
  ents.set(id, e)
  byUnique.set(e.uid, id)
})

client.on('set_entity_data', (p) => {
  const e = ents.get(key(p.runtime_entity_id))
  if (!e || e.name) return
  e.name = nameFrom(p.metadata)
})

client.on('set_entity_motion', (p) => {
  const e = ents.get(key(p.runtime_entity_id))
  if (e && e.name && phase === 'wander') { e.motion++; motionPackets++ }
})

// Link type 0 removes a link; 1 and 2 put the rider on the vehicle.
client.on('set_entity_link', (p) => {
  const l = p.link || {}
  if (l.type === 0) return
  const id = byUnique.get(key(l.rider_entity_id))
  const e = id === undefined ? null : ents.get(id)
  if (e && e.name) { e.rode = true; linkPackets++ }
})

function onMove (id, kind, next) {
  const e = ents.get(id)
  if (!e) return
  const step = dist(e.pos, next)
  e.pos = next
  if (!e.name || step === 0) return
  if (phase === 'wander') {
    e.steps.push({ s: step, t: Date.now() })
    e.moves++
    if (kind === 'abs') e.abs++
  } else if (phase === 'settle') {
    e.settleMoves++
    e.settleDist += step
    e.lastSettleAt = Date.now()
  } else if (phase === 'frozen') {
    e.post += step
    e.postMoves++
  }
}

client.on('move_entity_delta', (p) => {
  const id = key(p.runtime_entity_id)
  const e = ents.get(id)
  if (!e) return
  // Each axis is optional and holds the absolute position when present.
  const has = (v) => v !== undefined && v !== null
  onMove(id, 'delta', { x: has(p.x) ? p.x : e.pos.x, y: has(p.y) ? p.y : e.pos.y, z: has(p.z) ? p.z : e.pos.z })
})

client.on('move_entity', (p) => {
  const id = key(p.runtime_entity_id)
  if (!ents.has(id)) return
  onMove(id, 'abs', { x: p.position.x, y: p.position.y, z: p.position.z })
})

client.on('remove_entity', (p) => {
  const id = byUnique.get(key(p.entity_id_self))
  if (id === undefined) return
  const e = ents.get(id)
  if (e && e.name) {
    removedNamed++
    log(`remove_entity ${e.name} (${e.type}) in phase ${phase}`)
  }
  ents.delete(id)
  byUnique.delete(key(p.entity_id_self))
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

const named = () => [...ents.values()].filter((e) => e.name)
const quantile = (sorted, q) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : 0
const median = (arr) => quantile([...arr].sort((a, b) => a - b), 0.5)

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

  const summoned = Number(await waitFile('wander'))
  phase = 'wander'
  const seen = named()
  const types = {}
  for (const e of seen) types[e.type] = (types[e.type] || 0) + 1
  log(`wander start: server summoned ${summoned}, Bedrock add_entity with a b4m name ${seen.length}: ` +
    Object.entries(types).map(([t, n]) => `${t}=${n}`).join(' '))
  ack('wander')

  await waitFile('settle')
  phase = 'settle'
  const tSettle = Date.now()
  log('settle start: events over, every mob has NoAI, server still ticking')
  ack('settle')

  const readPos = (text) => {
    const m = new Map()
    for (const line of text.split('\n')) {
      const [n, x, y, z] = line.trim().split(/\s+/)
      if (NAME_RE.test(n || '') && [x, y, z].map(Number).every(Number.isFinite)) {
        m.set(n, { x: Number(x), y: Number(y), z: Number(z) })
      }
    }
    return m
  }
  const pre = readPos(await waitFile('pre'))
  log(`server Pos before the freeze for ${pre.size} mobs`)
  ack('pre')

  await waitFile('frozen')
  phase = 'frozen'
  tFreeze = Date.now()
  log(`frozen after ${tFreeze - tSettle} ms of settle`)
  ack('frozen')

  await waitFile('snap')
  // The server is frozen. A mob that stopped during the settle has no lerp
  // left, so these are the positions the Bedrock client keeps showing.
  const snap = new Map()
  for (const e of named()) snap.set(e.name, { type: e.type, pos: { ...e.pos }, e })
  log(`snapshot of ${snap.size} named mobs`)
  ack('snap')

  const truth = readPos(await waitFile('truth'))
  ack('truth')
  await waitFile('end')

  // Drift: snapshot against server Pos, every mob type here has Bedrock offset 0.
  const all = []
  for (const [n, s] of snap) {
    const t = truth.get(n)
    if (!t) continue
    const p = pre.get(n)
    const serverMove = p ? dist(p, t) : null
    const late = s.e.lastSettleAt >= tFreeze - LATE_MS || s.e.postMoves > 0
    const moving = late || serverMove === null || serverMove > SERVER_EPS
    all.push({ n, type: s.type, d: dist(s.pos, t), h: Math.hypot(s.pos.x - t.x, s.pos.z - t.z), shown: s.pos, t, e: s.e, serverMove, moving })
  }
  all.sort((a, b) => b.d - a.d)
  const riders = all.filter((r) => r.e.rode)
  // Verdict rows: never rode, and at rest on both sides at the freeze.
  const movers = all.filter((r) => !r.e.rode && r.moving)
  const rows = all.filter((r) => !r.e.rode && !r.moving)
  const ds = rows.map((r) => r.d).sort((a, b) => a - b)
  const mean = ds.length ? ds.reduce((a, b) => a + b, 0) / ds.length : 0
  const over = rows.filter((r) => r.d > LIMIT).length
  const over01 = rows.filter((r) => r.d > 0.1).length
  const riderMax = riders.reduce((a, r) => Math.max(a, r.d), 0)
  const riderOver = riders.filter((r) => r.d > LIMIT).length
  const moverMax = movers.reduce((a, r) => Math.max(a, r.d), 0)
  const moverOver = movers.filter((r) => r.d > LIMIT).length
  for (const r of all.slice(0, 12)) {
    log(`drift ${r.n} ${r.type}${r.e.rode ? ' (rode)' : ''}${r.moving ? ' (moving)' : ''}: ` +
      `Bedrock ${fv(r.shown)} server ${fv(r.t)} ` +
      `d=${r.d.toFixed(3)} h=${r.h.toFixed(3)} moves=${r.e.moves} move_entity=${r.e.abs} ` +
      `settle_moves=${r.e.settleMoves} settle_dist=${r.e.settleDist.toFixed(3)} ` +
      `last_settle_move=${r.e.lastSettleAt ? `${r.e.lastSettleAt - tFreeze}ms` : 'none'} ` +
      `server_move=${r.serverMove === null ? 'no_pre' : r.serverMove.toFixed(3)} ` +
      `post_freeze_moves=${r.e.postMoves} post_freeze_dist=${r.e.post.toFixed(3)}`)
  }
  log(`riders, left out of the verdict: ${riders.length}, drift max ${riderMax.toFixed(3)}, over ${LIMIT}: ${riderOver}`)
  log(`still moving at the freeze, left out of the verdict: ${movers.length}, drift max ${moverMax.toFixed(3)}, ` +
    `over ${LIMIT}: ${moverOver}` + (movers.length ? ` (${movers.slice(0, 10).map((r) => r.n).join(' ')})` : ''))

  // Stutter (INFO): per mob, how often one Bedrock step is over 3x its
  // median. "all" counts every step, "excl" leaves out steps within KICK_MS
  // after a kick of that mob, "calm" counts only mobs never kicked or ridden.
  const kicks = new Map()
  let kickLines = 0
  try {
    for (const line of fs.readFileSync(path.join(dir, 'kicks'), 'utf8').split('\n')) {
      const [n, ms] = line.trim().split(/\s+/)
      if (!NAME_RE.test(n || '') || !Number.isFinite(Number(ms))) continue
      if (!kicks.has(n)) kicks.set(n, [])
      kicks.get(n).push(Number(ms))
      kickLines++
    }
  } catch (e) {}
  const kicked = (e, t) => (kicks.get(e.name) || []).some((k) => t >= k && t <= k + KICK_MS)
  const bucket = () => ({ steps: 0, jumps: 0, max: 0, at: '' })
  const st = { all: bucket(), excl: bucket(), calm: bucket() }
  const add = (b, e, m, s) => {
    b.steps++
    if (m >= 0.01 && s > 3 * m) b.jumps++
    if (s > b.max) { b.max = s; b.at = `${e.name} ${e.type} median=${m.toFixed(3)}` }
  }
  let moved = 0
  const allNamed = [...snap.values()].map((s) => s.e)
  for (const e of allNamed) {
    if (e.moves > 0) moved++
    if (!e.steps.length) continue
    const m = median(e.steps.map((x) => x.s))
    const calm = !e.rode && !kicks.has(e.name)
    for (const { s, t } of e.steps) {
      add(st.all, e, m, s)
      if (!kicked(e, t)) add(st.excl, e, m, s)
      if (calm) add(st.calm, e, m, s)
    }
  }
  const postMoved = allNamed.filter((e) => e.postMoves > 0)
  const postMax = postMoved.reduce((a, e) => Math.max(a, e.post), 0)
  const settleMoved = allNamed.filter((e) => e.settleMoves > 0)
  const settleLate = allNamed.filter((e) => e.lastSettleAt >= tFreeze - LATE_MS)
  const serverMoved = all.filter((r) => r.serverMove !== null && r.serverMove > SERVER_EPS)
  const serverMax = serverMoved.reduce((a, r) => Math.max(a, r.serverMove), 0)
  const noPre = all.filter((r) => r.serverMove === null).length
  for (const [k, b] of Object.entries(st)) {
    log(`stutter ${k}: steps=${b.steps} over_3x_median=${b.jumps} max_jump=${b.max.toFixed(3)} (${b.at})`)
  }
  log(`kick lines ${kickLines} for ${kicks.size} mobs, window ${KICK_MS} ms; ` +
    `set_entity_motion=${motionPackets} set_entity_link=${linkPackets}`)
  log(`settle: ${settleMoved.length} mobs moved on Bedrock after NoAI, ` +
    `${settleLate.length} of them in the last ${LATE_MS} ms before the freeze`)
  log(`after freeze: ${postMoved.length} mobs still moved on Bedrock, largest total ${postMax.toFixed(3)}`)
  log(`server Pos changed across the freeze for ${serverMoved.length} mobs (largest ${serverMax.toFixed(3)}), ` +
    `no pre read for ${noPre}`)

  const why = []
  if (summoned < MIN_MOBS) why.push(`server summoned ${summoned} < ${MIN_MOBS}`)
  if (rows.length < MIN_MOBS) {
    why.push(`only ${rows.length} settled non-rider mobs matched between Bedrock and server ` +
      `(< ${MIN_MOBS}; ${movers.length} still moving)`)
  }
  if (moved * 2 < snap.size) why.push(`only ${moved} of ${snap.size} mobs moved on Bedrock during the wander`)
  const metrics = `mobs_server=${summoned} mobs_bedrock=${snap.size} matched=${all.length - riders.length} ` +
    `settled=${rows.length} riders=${riders.length} moving=${movers.length} ` +
    `moved=${moved} removed=${removedNamed} drift_max=${quantile(ds, 1).toFixed(3)} ` +
    `drift_p95=${quantile(ds, 0.95).toFixed(3)} drift_mean=${mean.toFixed(3)} over_${LIMIT}=${over} over_0.1=${over01} ` +
    `rider_drift_max=${riderMax.toFixed(3)} rider_over=${riderOver} ` +
    `moving_drift_max=${moverMax.toFixed(3)} moving_over=${moverOver} ` +
    `settle_moved=${settleMoved.length} settle_moved_last_${LATE_MS}ms=${settleLate.length} ` +
    `server_moved=${serverMoved.length} ` +
    `jumps_all=${st.all.jumps}/${st.all.steps} jumps_excl_kicks=${st.excl.jumps}/${st.excl.steps} ` +
    `jumps_calm=${st.calm.jumps}/${st.calm.steps} max_jump_all=${st.all.max.toFixed(3)} ` +
    `max_jump_excl=${st.excl.max.toFixed(3)} post_freeze_moved=${postMoved.length} limit=${LIMIT}`
  if (why.length) {
    writeResult(`PRECONDITION ${why.join('; ')} ${metrics}`)
    ack('end')
    return finish(3, why.join('; '))
  }
  writeResult(`${over > 0 ? 'FAIL' : 'PASS'} ${metrics}`)
  ack('end')
  finish(0, metrics)
}

client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
