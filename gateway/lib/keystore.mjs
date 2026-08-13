/**
 * Holds the upstream API key in memory for a bounded time.
 *
 * There is deliberately no persistence of any kind: the key exists in this
 * object's heap and nowhere else, so it disappears when the process does.
 */
export class KeyStore {
  #key = null
  #expiresAt = null

  constructor({ ttlMs, now = Date.now }) {
    this.ttlMs = ttlMs
    this.now = now
  }

  set(key) {
    this.#key = key
    this.#expiresAt = this.now() + this.ttlMs
  }

  get() {
    if (this.#key === null) return null
    if (this.now() > this.#expiresAt) {
      this.lock()
      return null
    }
    return this.#key
  }

  status() {
    const live = this.get() !== null
    return { locked: !live, expiresAt: live ? this.#expiresAt : null }
  }

  lock() {
    this.#key = null
    this.#expiresAt = null
  }
}
