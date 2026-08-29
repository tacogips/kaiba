import { describe, expect, test } from 'bun:test'
import {
  defaultServerEndpoint,
  isTauriRuntime,
  normalizeServerEndpoint,
  readServerEndpoint,
  resolveServerRequest,
  saveServerEndpoint,
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

  test('drops the stored credential when the endpoint origin changes', () => {
    const storage = memoryStorage('https://a.example.test', 'bearer-issued-by-a')
    saveServerEndpoint('https://b.example.test', storage)
    expect(storage.values.get(serverCredentialStorageKey)).toBeUndefined()
  })

  test('drops the stored credential when moving off the default endpoint', () => {
    const storage = memoryStorage(undefined, 'bearer-issued-by-the-default-host')
    saveServerEndpoint('http://192.168.1.10:8787', storage)
    expect(storage.values.get(serverCredentialStorageKey)).toBeUndefined()
  })

  test('keeps the stored credential when the same origin is re-saved', () => {
    const storage = memoryStorage('https://a.example.test', 'bearer-issued-by-a')
    saveServerEndpoint('https://a.example.test/', storage)
    expect(storage.values.get(serverCredentialStorageKey)).toBe('bearer-issued-by-a')
    expect(storage.values.get(serverEndpointStorageKey)).toBe('https://a.example.test')
  })

  test('detects only globals carrying Tauri internals', () => {
    expect(isTauriRuntime({})).toBe(false)
    expect(isTauriRuntime({ __TAURI_INTERNALS__: {} })).toBe(true)
  })
})
