import { test } from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import fs from 'node:fs'
import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const OC_KEY = fileURLToPath(new URL('../oc-key', import.meta.url))

/** Admin server stand-in that records the raw lines it was sent. */
function fakeAdmin(socketPath, received) {
  const server = net.createServer((sock) => {
    sock.on('data', (d) => {
      received.push(d.toString().trim())
      sock.write(JSON.stringify({ ok: true, locked: false, expiresAt: 1234 }) + '\n')
    })
  })
  return new Promise((resolve) => server.listen(socketPath, () => resolve(server)))
}

function run(args, opts = {}) {
  return new Promise((resolve) => {
    const child = execFile(
      OC_KEY,
      args,
      { env: { ...process.env, ...opts.env } },
      (err, stdout, stderr) => resolve({ code: err?.code ?? 0, stdout, stderr })
    )
    if (opts.stdin !== undefined) {
      child.stdin.write(opts.stdin)
      child.stdin.end()
    }
  })
}

async function withFakeAdmin(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ockey-'))
  const socketPath = path.join(dir, 'admin.sock')
  const received = []
  const server = await fakeAdmin(socketPath, received)
  try {
    await fn({ socketPath, received })
  } finally {
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

test('unlock --from prompt sends the key it reads from stdin', async () => {
  await withFakeAdmin(async ({ socketPath, received }) => {
    const res = await run(['unlock', '--from', 'prompt', '--socket', socketPath], {
      stdin: 'sk-typed-key\n',
    })

    assert.equal(res.code, 0)
    assert.deepEqual(JSON.parse(received[0]), { op: 'set-key', key: 'sk-typed-key' })
    assert.equal(res.stdout.includes('sk-typed-key'), false)
    assert.equal(res.stderr.includes('sk-typed-key'), false)
    assert.match(res.stdout, /unlocked/)
  })
})

test('unlock escapes a key containing json metacharacters', async () => {
  await withFakeAdmin(async ({ socketPath, received }) => {
    const res = await run(['unlock', '--from', 'prompt', '--socket', socketPath], {
      stdin: 'sk-"quote\\backslash\n',
    })

    assert.equal(res.code, 0)
    assert.deepEqual(JSON.parse(received[0]), { op: 'set-key', key: 'sk-"quote\\backslash' })
  })
})

test('unlock refuses an empty key', async () => {
  await withFakeAdmin(async ({ socketPath, received }) => {
    const res = await run(['unlock', '--from', 'prompt', '--socket', socketPath], { stdin: '\n' })

    assert.notEqual(res.code, 0)
    assert.match(res.stderr, /empty key/)
    assert.equal(received.length, 0)
  })
})

test('status prints the lock state', async () => {
  await withFakeAdmin(async ({ socketPath, received }) => {
    const res = await run(['status', '--socket', socketPath])

    assert.equal(res.code, 0)
    assert.deepEqual(JSON.parse(received[0]), { op: 'status' })
    assert.match(res.stdout, /unlocked/)
  })
})

test('lock sends the lock op', async () => {
  await withFakeAdmin(async ({ socketPath, received }) => {
    const res = await run(['lock', '--socket', socketPath])

    assert.equal(res.code, 0)
    assert.deepEqual(JSON.parse(received[0]), { op: 'lock' })
  })
})

test('fails clearly when the socket is missing', async () => {
  const res = await run(['status', '--socket', '/nonexistent/admin.sock'])
  assert.notEqual(res.code, 0)
  assert.match(res.stderr, /\/nonexistent\/admin\.sock/)
})

test('rejects an unknown subcommand', async () => {
  const res = await run(['frobnicate'])
  assert.equal(res.code, 2)
  assert.match(res.stderr, /usage/)
})
