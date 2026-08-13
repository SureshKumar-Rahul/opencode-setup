/**
 * Newline-delimited JSON control protocol for the gateway.
 *
 * Operations: set-key, status, lock. There is deliberately no operation that
 * returns a stored key, which is why exposing this socket to the human user's
 * group is safe: pushing a key in tells an attacker nothing.
 */
export function createAdminHandler({ keystore, log }) {
  return function handle(socket) {
    let buf = ''

    socket.on('data', (chunk) => {
      buf += chunk
      // Cap the buffer so a rogue client cannot grow it without bound.
      if (buf.length > 64 * 1024) {
        socket.end(JSON.stringify({ ok: false, error: 'request too large' }) + '\n')
        return
      }
      let idx
      while ((idx = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, idx)
        buf = buf.slice(idx + 1)
        socket.write(JSON.stringify(dispatch(line)) + '\n')
      }
    })

    socket.on('error', (err) => log({ event: 'admin-error', code: err.code }))

    function dispatch(line) {
      let msg
      try {
        msg = JSON.parse(line)
      } catch {
        return { ok: false, error: 'invalid json' }
      }
      switch (msg.op) {
        case 'set-key': {
          if (typeof msg.key !== 'string' || msg.key.length === 0) {
            return { ok: false, error: 'key must be a non-empty string' }
          }
          keystore.set(msg.key)
          log({ event: 'key-set' })
          return { ok: true }
        }
        case 'status': {
          const s = keystore.status()
          return { ok: true, locked: s.locked, expiresAt: s.expiresAt }
        }
        case 'lock': {
          keystore.lock()
          log({ event: 'locked-by-admin' })
          return { ok: true }
        }
        default:
          return { ok: false, error: `unknown op: ${String(msg.op)}` }
      }
    }
  }
}
