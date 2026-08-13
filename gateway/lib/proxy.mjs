import http from 'node:http'
import https from 'node:https'

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailers',
  'transfer-encoding',
  'upgrade',
])

function deny(res, status, message) {
  const body = JSON.stringify({ error: { message } })
  res.writeHead(status, { 'Content-Type': 'application/json' })
  res.end(body)
}

/**
 * Build the request handler.
 *
 * The upstream is fixed at construction time and can never be influenced by
 * the client: the Host header is overwritten and absolute-form request lines
 * are refused, so there is no way to aim this proxy at another host.
 */
export function createProxyHandler({ keystore, upstream, log }) {
  const transport = upstream.protocol === 'https:' ? https : http
  const agent = new transport.Agent({ keepAlive: true })

  return function handle(req, res) {
    const started = Date.now()

    if (!req.url.startsWith('/')) {
      log({ event: 'blocked', reason: 'absolute-form', method: req.method })
      return deny(res, 403, 'gateway forwards only to its configured upstream')
    }

    const key = keystore.get()
    if (key === null) {
      log({ event: 'locked', method: req.method, path: req.url })
      return deny(res, 401, 'gateway locked: run oc-key unlock')
    }

    const headers = {}
    for (const [name, value] of Object.entries(req.headers)) {
      if (!HOP_BY_HOP.has(name.toLowerCase())) headers[name] = value
    }
    headers.host = `${upstream.hostname}:${upstream.port}`
    headers.authorization = `Bearer ${key}`

    const proxyReq = transport.request(
      {
        protocol: upstream.protocol,
        hostname: upstream.hostname,
        port: upstream.port,
        method: req.method,
        path: req.url,
        headers,
        agent,
      },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode ?? 502, proxyRes.headers)
        proxyRes.pipe(res)
        proxyRes.on('end', () =>
          log({
            event: 'proxied',
            method: req.method,
            path: req.url,
            status: proxyRes.statusCode,
            ms: Date.now() - started,
          })
        )
      }
    )

    proxyReq.on('error', (err) => {
      log({ event: 'upstream-error', code: err.code, path: req.url })
      if (!res.headersSent) deny(res, 502, 'upstream request failed')
      else res.destroy()
    })

    req.pipe(proxyReq)
  }
}
