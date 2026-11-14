import { describe, expect, test } from 'bun:test'
import {
  assertServerOrigin,
  currentServerCredentialKey,
  defaultServerEndpoint,
  isTauriRuntime,
  normalizeServerEndpoint,
  readServerEndpoint,
  resolveServerRequest,
  saveServerEndpoint,
  serverCredentialKey,
  serverCredentialStorageKey,
  serverEndpointStorageKey,
} from './serverEndpoint'

function memoryStorage(initial?: string, credential?: string) {
  const values = new Map<string, string>()
  if (initial) values.set(serverEndpointStorageKey, initial)
  if (credential) values.set(serverCredentialStorageKey, credential)
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value) },
    removeItem: (key: string) => { values.delete(key) },
    values,
  }
}

describe('native server endpoint', () => {
  test('normalizes HTTP server origins', () => {
    expect(normalizeServerEndpoint(' https://notes.example.test/ '))
      .toBe('https://notes.example.test')
  })

  test('rejects unsafe or ambiguous endpoint forms', () => {
    expect(() => normalizeServerEndpoint('file:///tmp/store')).toThrow('HTTP or HTTPS')
    expect(() => normalizeServerEndpoint('https://user:secret@example.test')).toThrow('credentials')
    expect(() => normalizeServerEndpoint('https://example.test?q=1')).toThrow('query or fragment')
    expect(() => normalizeServerEndpoint('https://example.test/kaiba')).toThrow('path')
  })

  test('stores a normalized endpoint and falls back from invalid persisted data', () => {
    const storage = memoryStorage()
    expect(saveServerEndpoint('http://192.168.1.10:8787/', storage)).toBe('http://192.168.1.10:8787')
    expect(readServerEndpoint(storage)).toBe('http://192.168.1.10:8787')
    expect(readServerEndpoint(memoryStorage('not a url'))).toBe(defaultServerEndpoint)
  })

  test('resolves note API paths against the configured native server', () => {
    expect(resolveServerRequest('/graphql', 'https://notes.example.test'))
      .toBe('https://notes.example.test/graphql')
    expect(resolveServerRequest('files/one', 'https://notes.example.test'))
      .toBe('https://notes.example.test/files/one')
  })

  test('keeps the query string on a resolved note API path', () => {
    expect(resolveServerRequest('/note/events?since=1', 'https://notes.example.test'))
      .toBe('https://notes.example.test/note/events?since=1')
  })

  test('keeps an absolute URL as its own target', () => {
    expect(resolveServerRequest('https://other.test/graphql', 'https://notes.example.test'))
      .toBe('https://other.test/graphql')
  })

  test('passes a non-string request target through untouched', () => {
    const target = new URL('https://other.test/graphql')
    expect(resolveServerRequest(target, 'https://notes.example.test')).toBe(target)
  })

  test('pins the storage key literals that persisted data depends on', () => {
    // Renaming either silently signs every existing install out.
    expect(serverCredentialStorageKey).toBe('kaiba-note-bearer')
    expect(serverEndpointStorageKey).toBe('kaiba-server-endpoint')
  })

  test('scopes a credential to the origin that issued it', () => {
    expect(serverCredentialKey('https://a.example.test'))
      .toBe(`${serverCredentialStorageKey}:https://a.example.test`)
    expect(serverCredentialKey('https://b.example.test'))
      .not.toBe(serverCredentialKey('https://a.example.test'))
  })

  test('does not expose one origin credential to another after a switch', () => {
    const storage = memoryStorage('https://a.example.test')
    storage.values.set(serverCredentialKey('https://a.example.test'), 'bearer-issued-by-a')
    saveServerEndpoint('https://b.example.test', storage)
    expect(currentServerCredentialKey(storage)).toBe(serverCredentialKey('https://b.example.test'))
    expect(storage.values.get(currentServerCredentialKey(storage))).toBeUndefined()
  })

  test('restores the original credential when a mistyped endpoint is corrected', () => {
    const storage = memoryStorage('https://notes.example.com')
    storage.values.set(serverCredentialKey('https://notes.example.com'), 'bearer-issued-by-notes')
    saveServerEndpoint('https://notes.exmaple.com', storage)
    expect(storage.values.get(currentServerCredentialKey(storage))).toBeUndefined()
    saveServerEndpoint('https://notes.example.com', storage)
    expect(storage.values.get(currentServerCredentialKey(storage))).toBe('bearer-issued-by-notes')
  })

  test('keeps the credential readable when the same origin is re-saved', () => {
    const storage = memoryStorage('https://a.example.test')
    storage.values.set(serverCredentialKey('https://a.example.test'), 'bearer-issued-by-a')
    saveServerEndpoint('https://a.example.test/', storage)
    expect(storage.values.get(currentServerCredentialKey(storage))).toBe('bearer-issued-by-a')
    expect(storage.values.get(serverEndpointStorageKey)).toBe('https://a.example.test')
  })

  test('files a pre-scoping credential under the outgoing origin instead of deleting it', () => {
    const storage = memoryStorage('https://a.example.test', 'bearer-issued-by-a')
    saveServerEndpoint('https://b.example.test', storage)
    expect(storage.values.get(serverCredentialStorageKey)).toBeUndefined()
    expect(storage.values.get(serverCredentialKey('https://a.example.test'))).toBe('bearer-issued-by-a')
    expect(storage.values.get(currentServerCredentialKey(storage))).toBeUndefined()
  })

  test('accepts a target that resolves to the configured server origin', () => {
    const endpoint = 'https://notes.example.test'
    expect(() => assertServerOrigin(resolveServerRequest('/graphql', endpoint), endpoint)).not.toThrow()
    expect(() => assertServerOrigin(resolveServerRequest('/note/events?since=1', endpoint), endpoint))
      .not.toThrow()
  })

  test('refuses a protocol-relative path that resolves off the configured origin', () => {
    const endpoint = 'https://notes.example.test'
    // `new URL('//other.test/x')` throws, so resolveServerRequest resolves it
    // against the endpoint base and yields a cross-origin target.
    expect(resolveServerRequest('//other.test/x', endpoint)).toBe('https://other.test/x')
    expect(() => assertServerOrigin(resolveServerRequest('//other.test/x', endpoint), endpoint))
      .toThrow('different origin')
  })

  test('refuses an absolute URL and a non-string target aimed at another host', () => {
    const endpoint = 'https://notes.example.test'
    expect(() => assertServerOrigin('https://other.test/graphql', endpoint)).toThrow('different origin')
    expect(() => assertServerOrigin(new URL('https://other.test/graphql'), endpoint))
      .toThrow('different origin')
    expect(() => assertServerOrigin(new Request('https://other.test/graphql'), endpoint))
      .toThrow('different origin')
  })

  test('detects only globals carrying Tauri internals', () => {
    expect(isTauriRuntime({})).toBe(false)
    expect(isTauriRuntime({ __TAURI_INTERNALS__: {} })).toBe(true)
  })
})
