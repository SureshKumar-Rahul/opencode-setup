import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import { startGateway } from '../oc-gateway.mjs'

function adminRequest(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(socketPath, () => c.write(JSON.stringify(payload) + '\n'))
    let buf = ''
    c.on('data', (d) => {
      buf += d
      if (buf.includes('\n')) {
        c.end()
        resolve(JSON.parse(buf.trim()))
      }
    })
    c.on('error', reject)
  })
}

test('serves http and admin together, and never logs the key', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ocgw-boot-'))
  const socketPath = path.join(dir, 'admin.sock')
  const lines = []

  const gw = await startGateway({
    port: 0,
    host: '127.0.0.1',
    socketPath,
    ttlMs: 10000,
    // Port 1 refuses connections, which is enough to prove the key was used.
    upstream: { protocol: 'http:', hostname: '127.0.0.1', port: 1 },
    out: (line) => lines.push(line),
  })

  const locked = await fetch(`http://127.0.0.1:${gw.port}/v1/models`)
  assert.equal(locked.status, 401)

  assert.deepEqual(await adminRequest(socketPath, { op: 'set-key', key: 'sk-canary-9f3b' }), { ok: true })

  const proxied = await fetch(`http://127.0.0.1:${gw.port}/v1/models`)
  assert.equal(proxied.status, 502)

  assert.equal(fs.statSync(socketPath).mode & 0o777, 0o660)
  assert.equal(lines.join('\n').includes('sk-canary-9f3b'), false)
  assert.ok(lines.some((l) => JSON.parse(l).event === 'listening'))

  await gw.close()
  assert.equal(fs.existsSync(socketPath), false)
  fs.rmSync(dir, { recursive: true, force: true })
})

test('rebinds over a stale socket file', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ocgw-stale-'))
  const socketPath = path.join(dir, 'admin.sock')
  fs.writeFileSync(socketPath, 'stale')

  const gw = await startGateway({
    port: 0,
    host: '127.0.0.1',
    socketPath,
    ttlMs: 10000,
    upstream: { protocol: 'http:', hostname: '127.0.0.1', port: 1 },
    out: () => {},
  })

  assert.deepEqual(await adminRequest(socketPath, { op: 'status' }), {
    ok: true,
    locked: true,
    expiresAt: null,
  })

  await gw.close()
  fs.rmSync(dir, { recursive: true, force: true })
})
