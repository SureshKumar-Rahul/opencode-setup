import { test } from 'node:test'
import assert from 'node:assert/strict'
import { KeyStore } from '../lib/keystore.mjs'

test('starts locked', () => {
  const ks = new KeyStore({ ttlMs: 1000 })
  assert.equal(ks.get(), null)
  assert.deepEqual(ks.status(), { locked: true, expiresAt: null })
})

test('returns the key once set', () => {
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-test')
  assert.equal(ks.get(), 'sk-test')
  assert.equal(ks.status().locked, false)
})

test('expires after the ttl', () => {
  let clock = 0
  const ks = new KeyStore({ ttlMs: 1000, now: () => clock })
  ks.set('sk-test')
  clock = 999
  assert.equal(ks.get(), 'sk-test')
  clock = 1001
  assert.equal(ks.get(), null)
  assert.equal(ks.status().locked, true)
})

test('lock clears immediately', () => {
  const ks = new KeyStore({ ttlMs: 1000 })
  ks.set('sk-test')
  ks.lock()
  assert.equal(ks.get(), null)
})

test('status reports the expiry while unlocked', () => {
  const ks = new KeyStore({ ttlMs: 1000, now: () => 5000 })
  ks.set('sk-test')
  assert.deepEqual(ks.status(), { locked: false, expiresAt: 6000 })
})
