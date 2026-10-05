import { describe, expect, test } from 'bun:test'
import { normalizedTarget, searchEngineSettingsInput, validateSearchEngineForm, type SearchEngineForm } from './searchEngineSettings'
import type { SearchEngineSettings } from './types'

const loaded: SearchEngineSettings = {
  managedBy: 'store', kind: 'example-engine', url: 'http://localhost:8080', indexPrefix: 'kaiba',
  authMode: 'basic', username: 'admin', hasSecret: true, verifyTLS: true,
  requestTimeoutSeconds: 10, adapters: [{ kind: 'example-engine', displayName: 'Example engine', authModes: ['none', 'basic', 'apiKey'] }], active: true,
}

function form(patch: Partial<SearchEngineForm> = {}): SearchEngineForm {
  return {
    kind: 'example-engine', url: 'http://localhost:8080', indexPrefix: 'kaiba', authMode: 'basic',
    username: 'admin', secret: '', clearSecret: false, verifyTLS: true, requestTimeoutSeconds: '10',
    ...patch,
  }
}

function fields(value: SearchEngineForm, source: SearchEngineSettings = loaded): string[] {
  return validateSearchEngineForm(value, source).map((error) => error.field)
}

describe('search engine settings validation', () => {
  test('accepts blank and whitespace URLs as the server default', () => {
    expect(fields(form({ url: '' }))).not.toContain('searchEngine.url')
    expect(fields(form({ url: '   ' }))).not.toContain('searchEngine.url')
    expect(searchEngineSettingsInput(form({ url: '' }))).not.toHaveProperty('url')
    expect(searchEngineSettingsInput(form({ url: '  ' }))).not.toHaveProperty('url')
  })

  test('retains stored secrets when both settings use the server default', () => {
    const serverDefault: SearchEngineSettings = { ...loaded, url: null, authMode: 'apiKey' }
    expect(fields(form({ url: '', authMode: 'apiKey' }), serverDefault)).not.toContain('searchEngine.secret')
  })

  test('rejects non-loopback http, bad prefixes and invalid timeouts', () => {
    expect(fields(form({ url: 'http://example.com:8080' }))).toContain('searchEngine.url')
    expect(fields(form({ indexPrefix: 'Bad Prefix' }))).toContain('searchEngine.indexPrefix')
    expect(fields(form({ requestTimeoutSeconds: '0' }))).toContain('searchEngine.requestTimeoutSeconds')
  })

  test('requires a username for basic authentication', () => {
    expect(fields(form({ username: ' ' }))).toContain('searchEngine.username')
    expect(fields(form({ username: 'u'.repeat(257) }))).toContain('searchEngine.username')
  })

  test('rejects oversized or control-character connection fields', () => {
    expect(fields(form({ url: `https://search.example.com/${'x'.repeat(2040)}` }))).toContain('searchEngine.url')
    expect(fields(form({ secret: 'x'.repeat(4097) }))).toContain('searchEngine.secret')
    expect(fields(form({ username: 'admin\n' }))).toContain('searchEngine.username')
  })

  test('requires a secret when the bound target or auth mode changes', () => {
    expect(fields(form())).not.toContain('searchEngine.secret')
    expect(fields(form({ url: 'http://localhost:9201' }))).toContain('searchEngine.secret')
    expect(fields(form({ authMode: 'apiKey' }))).toContain('searchEngine.secret')
    expect(fields(form({ url: 'http://localhost:9201', secret: 'new-secret' }))).not.toContain('searchEngine.secret')
  })

  test('allows disabled TLS verification only for https', () => {
    expect(fields(form({ verifyTLS: false }))).toContain('searchEngine.verifyTLS')
    expect(fields(form({ url: '', verifyTLS: false }))).toContain('searchEngine.verifyTLS')
    expect(fields(form({ url: 'https://search.example.com', verifyTLS: false }))).not.toContain('searchEngine.verifyTLS')
  })

  test('normalizes scheme and host and strips a trailing slash', () => {
    expect(normalizedTarget('HTTP://LocalHost:8080/')).toBe('http://localhost:8080')
  })

  test('omits a stale secret when authentication is disabled', () => {
    expect(searchEngineSettingsInput(form({ authMode: 'none', secret: 'stale-secret' }))).not.toHaveProperty('secret')
  })
})
