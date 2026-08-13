import { test } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import { KeyStore } from '../lib/keystore.mjs'
import { createProxyHandler } from '../lib/proxy.mjs'

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))
}

function close(server) {
  // Keep-alive sockets would otherwise hold close() open for seconds.
  return new Promise((resolve) => {
    server.closeAllConnections()
    server.close(() => resolve())
  })
}

/** Start a fake upstream that records what it received. */
async function fakeUpstream(handler) {
  const seen = {}
  const server = http.createServer(
    handler ??
      ((req, res) => {
        seen.url = req.url
        seen.auth = req.headers.authorization
        seen.host = req.headers.host
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
      })
  )
  const port = await listen(server)
  return { server, port, seen }
}

async function startGateway(keystore, upstreamPort) {
  const server = http.createServer(
    createProxyHandler({
      keystore,
      upstream: { protocol: 'http:', hostname: '127.0.0.1', port: upstreamPort },
      log: () => {},
    })
  )
  const port = await listen(server)
  return { server, port }
}

/** Raw request, so we can set headers fetch forbids (Host) and use absolute-form URLs. */
function rawRequest({ port, path, headers = {} }) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method: 'GET', path, headers }, (res) => {
      let body = ''
      res.on('data', (d) => (body += d))
      res.on('end', () => resolve({ status: res.statusCode, body }))
    })
    req.on('error', reject)
    req.end()
  })
}

test('returns 401 when locked', async () => {
  const up = await fakeUpstream()
  const gw = await startGateway(new KeyStore({ ttlMs: 1000 }), up.port)

  const res = await fetch(`http://127.0.0.1:${gw.port}/v1/models`)
  assert.equal(res.status, 401)
  assert.match((await res.json()).error.message, /oc-key unlock/)

  await close(gw.server)
  await close(up.server)
})

test('replaces the client authorization header', async () => {
  const up = await fakeUpstream()
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  const gw = await startGateway(ks, up.port)

  const res = await fetch(`http://127.0.0.1:${gw.port}/v1/models`, {
    headers: { authorization: 'Bearer placeholder' },
  })

  assert.equal(res.status, 200)
  assert.equal(up.seen.auth, 'Bearer sk-real-key')
  assert.equal(up.seen.url, '/v1/models')

  await close(gw.server)
  await close(up.server)
})

test('rewrites the host header to the upstream', async () => {
  const up = await fakeUpstream()
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  const gw = await startGateway(ks, up.port)

  await rawRequest({ port: gw.port, path: '/v1/models', headers: { host: 'evil.example.com' } })
  assert.equal(up.seen.host, `127.0.0.1:${up.port}`)

  await close(gw.server)
  await close(up.server)
})

test('refuses an absolute-form request aimed elsewhere', async () => {
  const up = await fakeUpstream()
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  const gw = await startGateway(ks, up.port)

  const res = await rawRequest({ port: gw.port, path: 'http://evil.example.com/v1/models' })
  assert.equal(res.status, 403)

  await close(gw.server)
  await close(up.server)
})

test('returns 502 when the upstream is unreachable', async () => {
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  // Port 1 is reserved and refuses connections.
  const gw = await startGateway(ks, 1)

  const res = await fetch(`http://127.0.0.1:${gw.port}/v1/models`)
  assert.equal(res.status, 502)

  await close(gw.server)
})

test('streams response chunks without buffering', async () => {
  const sse = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' })
    res.write('data: one\n\n')
    setTimeout(() => {
      res.write('data: two\n\n')
      res.end()
    }, 300)
  })
  const ssePort = await listen(sse)

  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  const gw = await startGateway(ks, ssePort)

  const started = Date.now()
  const res = await fetch(`http://127.0.0.1:${gw.port}/v1/chat/completions`)
  const reader = res.body.getReader()
  const first = await reader.read()
  const elapsed = Date.now() - started

  assert.match(new TextDecoder().decode(first.value), /one/)
  assert.ok(elapsed < 250, `first chunk took ${elapsed}ms, expected streaming not buffering`)

  await reader.cancel()
  await close(gw.server)
  await close(sse)
})

test('accepts a request body larger than 1 MB', async () => {
  let received = 0
  const sink = http.createServer((req, res) => {
    req.on('data', (c) => (received += c.length))
    req.on('end', () => {
      res.writeHead(200)
      res.end('{}')
    })
  })
  const sinkPort = await listen(sink)

  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-real-key')
  const gw = await startGateway(ks, sinkPort)

  const payload = 'x'.repeat(3 * 1024 * 1024)
  const res = await fetch(`http://127.0.0.1:${gw.port}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: payload,
  })

  assert.equal(res.status, 200)
  assert.equal(received, payload.length)

  await close(gw.server)
  await close(sink)
})
