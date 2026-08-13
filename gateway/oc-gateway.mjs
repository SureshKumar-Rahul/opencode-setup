#!/usr/bin/env node
import http from 'node:http'
import net from 'node:net'
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
import { KeyStore } from './lib/keystore.mjs'
import { createProxyHandler } from './lib/proxy.mjs'
import { createAdminHandler } from './lib/admin.mjs'

export async function startGateway({ port, host, socketPath, ttlMs, upstream, out = console.log }) {
  const log = (fields) => out(JSON.stringify({ ts: new Date().toISOString(), ...fields }))
  const keystore = new KeyStore({ ttlMs })

  const httpServer = http.createServer(createProxyHandler({ keystore, upstream, log }))
  await new Promise((resolve) => httpServer.listen(port, host, resolve))

  // A stale socket from an unclean shutdown would otherwise block the bind.
  fs.rmSync(socketPath, { force: true })
  const adminServer = net.createServer(createAdminHandler({ keystore, log }))
  await new Promise((resolve) => adminServer.listen(socketPath, resolve))
  // Node applies the umask when binding, so set the mode explicitly.
  fs.chmodSync(socketPath, 0o660)

  log({ event: 'listening', port: httpServer.address().port, socket: socketPath })

  return {
    port: httpServer.address().port,
    async close() {
      keystore.lock()
      httpServer.closeAllConnections()
      await new Promise((resolve) => adminServer.close(resolve))
      await new Promise((resolve) => httpServer.close(resolve))
      fs.rmSync(socketPath, { force: true })
    },
  }
}

const isEntryPoint =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href

if (isEntryPoint) {
  const gateway = await startGateway({
    port: Number(process.env.OC_GATEWAY_PORT ?? 4141),
    host: process.env.OC_GATEWAY_HOST ?? '127.0.0.1',
    socketPath: process.env.OC_GATEWAY_SOCKET ?? '/run/oc-gateway/admin.sock',
    ttlMs: Number(process.env.OC_GATEWAY_TTL_SECONDS ?? 28800) * 1000,
    upstream: { protocol: 'https:', hostname: 'llm.scads.ai', port: 443 },
  })

  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.on(signal, () => {
      gateway.close().then(() => process.exit(0))
    })
  }
}
