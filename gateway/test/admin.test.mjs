import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import { KeyStore } from '../lib/keystore.mjs'
import { createAdminHandler } from '../lib/admin.mjs'

async function withServer(keystore, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ocgw-'))
  const sock = path.join(dir, 'admin.sock')
  const server = net.createServer(createAdminHandler({ keystore, log: () => {} }))
  await new Promise((r) => server.listen(sock, r))
  try {
    await fn(sock)
  } finally {
    await new Promise((r) => server.close(r))
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

function request(sock, payload) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sock, () => c.write(JSON.stringify(payload) + '\n'))
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

/** Send a raw string rather than JSON, for malformed-input cases. */
function requestRaw(sock, line) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sock, () => c.write(line + '\n'))
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

test('set-key stores the key', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  await withServer(ks, async (sock) => {
    assert.deepEqual(await request(sock, { op: 'set-key', key: 'sk-abc' }), { ok: true })
    assert.equal(ks.get(), 'sk-abc')
  })
})

test('status never returns the key', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  ks.set('sk-secret-value')
  await withServer(ks, async (sock) => {
    const res = await request(sock, { op: 'status' })
    assert.equal(res.locked, false)
    assert.equal(JSON.stringify(res).includes('sk-secret-value'), false)
  })
})

test('lock clears the key', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  ks.set('sk-abc')
  await withServer(ks, async (sock) => {
    assert.deepEqual(await request(sock, { op: 'lock' }), { ok: true })
    assert.equal(ks.get(), null)
  })
})

test('there is no operation that reads the key back', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  ks.set('sk-secret-value')
  await withServer(ks, async (sock) => {
    for (const op of ['get-key', 'get', 'read', 'dump', 'export']) {
      const res = await request(sock, { op })
      assert.equal(res.ok, false)
      assert.equal(JSON.stringify(res).includes('sk-secret-value'), false)
    }
  })
})

test('rejects an empty key', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  await withServer(ks, async (sock) => {
    assert.equal((await request(sock, { op: 'set-key', key: '' })).ok, false)
    assert.equal(ks.get(), null)
  })
})

test('rejects malformed json', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  await withServer(ks, async (sock) => {
    const res = await requestRaw(sock, '{not json')
    assert.equal(res.ok, false)
    assert.match(res.error, /invalid json/)
  })
})

test('handles two requests on one connection', async () => {
  const ks = new KeyStore({ ttlMs: 10000 })
  await withServer(ks, async (sock) => {
    const replies = await new Promise((resolve, reject) => {
      const c = net.createConnection(sock, () => {
        c.write(JSON.stringify({ op: 'set-key', key: 'sk-abc' }) + '\n')
        c.write(JSON.stringify({ op: 'status' }) + '\n')
      })
      let buf = ''
      c.on('data', (d) => {
        buf += d
        const lines = buf.split('\n').filter(Boolean)
        if (lines.length >= 2) {
          c.end()
          resolve(lines.map((l) => JSON.parse(l)))
        }
      })
      c.on('error', reject)
    })
    assert.deepEqual(replies[0], { ok: true })
    assert.equal(replies[1].locked, false)
  })
})
