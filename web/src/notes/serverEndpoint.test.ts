import { describe, expect, test } from 'bun:test'
import {
  assertServerOrigin,
  activeConnectionLabel,
  connectionModeStorageKey,
  currentServerCredentialKey,
  defaultServerEndpoint,
  isTauriRuntime,
  isUnencryptedRemoteEndpoint,
  normalizeServerEndpoint,
  readRecentServerEndpoints,
  readServerEndpoint,
  recentServerEndpointLimit,
  recentServerEndpointsStorageKey,
  recordRecentServerEndpoint,
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
  test('reads an empty recent endpoint list from empty storage', () => {
    expect(readRecentServerEndpoints(memoryStorage())).toEqual([])
  })

  test('ignores corrupt or non-array recent endpoint data', () => {
    for (const value of ['not json', '{"a":1}']) {
      const storage = memoryStorage()
      storage.values.set(recentServerEndpointsStorageKey, value)
      expect(readRecentServerEndpoints(storage)).toEqual([])
    }
  })

  test('normalizes valid recent endpoints and drops invalid and duplicate entries', () => {
    const storage = memoryStorage()
    storage.values.set(recentServerEndpointsStorageKey, JSON.stringify([
      'https://a.example/', 'ftp://x', 42, 'https://a.example', 'http://b.example:8787',
    ]))
    expect(readRecentServerEndpoints(storage)).toEqual(['https://a.example', 'http://b.example:8787'])
  })

  test('caps recent endpoint reads at the configured limit', () => {
    const storage = memoryStorage()
    storage.values.set(recentServerEndpointsStorageKey, JSON.stringify(
      Array.from({ length: recentServerEndpointLimit + 2 }, (_, index) => `https://${index}.example`),
    ))
    expect(readRecentServerEndpoints(storage)).toHaveLength(recentServerEndpointLimit)
  })

  test('records a normalized endpoint first and evicts the oldest entry', () => {
    const storage = memoryStorage()
    const existing = Array.from({ length: recentServerEndpointLimit }, (_, index) => `https://${index}.example`)
    storage.values.set(recentServerEndpointsStorageKey, JSON.stringify(existing))
    const result = recordRecentServerEndpoint('https://new.example/', storage)
    expect(result).toEqual(['https://new.example', ...existing.slice(0, -1)])
    expect(storage.values.get(recentServerEndpointsStorageKey)).toBe(JSON.stringify(result))
  })

  test('moves a re-recorded endpoint to the front without duplication', () => {
    const storage = memoryStorage()
    storage.values.set(recentServerEndpointsStorageKey, JSON.stringify([
      'https://a.example', 'https://b.example', 'https://c.example',
    ]))
    expect(recordRecentServerEndpoint('https://b.example/', storage))
      .toEqual(['https://b.example', 'https://a.example', 'https://c.example'])
  })

  test('rejects invalid recent endpoints without changing storage', () => {
    const storage = memoryStorage()
    storage.values.set(recentServerEndpointsStorageKey, 'unchanged')
    expect(() => recordRecentServerEndpoint('https://x.example/path', storage)).toThrow('must not contain a path')
    expect(storage.values.get(recentServerEndpointsStorageKey)).toBe('unchanged')
  })

  test('preserves all bearer values when recording and evicting recent endpoints', () => {
    const storage = memoryStorage()
    const existing = Array.from({ length: recentServerEndpointLimit }, (_, index) => `https://${index}.example`)
    storage.values.set(recentServerEndpointsStorageKey, JSON.stringify(existing))
    for (const endpoint of existing) storage.values.set(serverCredentialKey(endpoint), `bearer:${endpoint}`)
    const credentials = [...storage.values].filter(([key]) => key.startsWith(`${serverCredentialStorageKey}:`))
    recordRecentServerEndpoint('https://new.example', storage)
    expect([...storage.values].filter(([key]) => key.startsWith(`${serverCredentialStorageKey}:`)))
      .toEqual(credentials)
  })

  test('warns for non-loopback HTTP endpoints only', () => {
    expect(isUnencryptedRemoteEndpoint('http://192.168.1.20:8787')).toBe(true)
    expect(isUnencryptedRemoteEndpoint('http://notes.example.com')).toBe(true)
    for (const endpoint of [
      'http://127.0.0.1:8787', 'http://127.1:8787', 'http://localhost:8787',
      'http://[::1]:8787', 'https://192.168.1.20', 'garbage',
    ]) expect(isUnencryptedRemoteEndpoint(endpoint)).toBe(false)
  })

  test('labels the active local or remote connection', () => {
    const storage = memoryStorage()
    storage.values.set(connectionModeStorageKey, 'local')
    expect(activeConnectionLabel(storage)).toBe('Local — this Mac')
    storage.values.set(connectionModeStorageKey, 'remote')
    storage.values.set(serverEndpointStorageKey, 'https://notes.example.com:8443')
    expect(activeConnectionLabel(storage)).toBe('Remote — notes.example.com:8443')
    storage.values.delete(serverEndpointStorageKey)
    expect(activeConnectionLabel(storage)).toBe(`Remote — ${new URL(defaultServerEndpoint).host}`)
  })

  test('permits configured HTTP and HTTPS hosts on any port in the native shell', async () => {
    const capabilityUrl = new URL('../../src-tauri/capabilities/default.json', import.meta.url)
    const capability = await Bun.file(capabilityUrl).json() as {
      permissions: Array<string | { identifier: string; allow: Array<{ url: string }> }>
    }
    const permission = capability.permissions.find(
      (entry): entry is { identifier: string; allow: Array<{ url: string }> } =>
        typeof entry !== 'string' && entry.identifier === 'http:default',
    )
    expect(permission?.allow.map((entry) => entry.url)).toEqual(['http://*:*', 'https://*:*'])
  })

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
