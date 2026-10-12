// Joins the test server as one Bedrock bot, stays STAY_SECS after spawn, then leaves.
// Exits 0 on a clean stay, 1 on kick, disconnect, error or spawn timeout.
const bedrock = require('bedrock-protocol')

const name = process.env.BOT_NAME || 'Bot1'
const stay = Number(process.env.STAY_SECS || 30)
const spawnTimeout = Number(process.env.SPAWN_TIMEOUT_SECS || 120)
if (!(stay > 0) || !(spawnTimeout > 0)) {
  console.log(`bot ${name}: FAIL bad STAY_SECS or SPAWN_TIMEOUT_SECS`)
  process.exit(2)
}

const options = {
  host: '127.0.0.1',
  port: 19132,
  username: name,
  offline: true,
  version: process.env.BEDROCK_VERSION || '1.26.51'
}

let done = false
function finish (code, why) {
  if (done) return
  done = true
  console.log(`bot ${name}: ${code === 0 ? 'PASS' : 'FAIL'} ${why}`)
  try { client.close() } catch (e) {}
  setTimeout(() => process.exit(code), 500)
}

const client = bedrock.createClient(options)
const spawnTimer = setTimeout(() => finish(1, `no spawn within ${spawnTimeout} s`), spawnTimeout * 1000)

client.on('spawn', () => {
  clearTimeout(spawnTimer)
  console.log(`bot ${name}: spawned, staying ${stay} s`)
  setTimeout(() => finish(0, `stayed ${stay} s`), stay * 1000)
})
client.on('kick', (p) => finish(1, `kicked: ${JSON.stringify(p)}`))
client.on('disconnect', (p) => finish(1, `disconnected: ${JSON.stringify(p)}`))
client.on('close', () => finish(1, 'connection closed'))
client.on('error', (e) => finish(1, `error: ${e && e.stack ? e.stack : e}`))
