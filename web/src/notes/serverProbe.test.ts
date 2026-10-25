import { describe, expect, test } from 'bun:test'
import {
  describeServerProbe,
  serverProbeTimeoutMs,
  testServerConnection,
  type ProbeFetch,
} from './serverProbe'
import { serverCredentialKey } from './serverEndpoint'

const endpoint = 'https://notes.example.com'
const health = () => new Response(JSON.stringify({ service: 'kaiba', status: 'ok' }), { status: 200 })

function scriptedFetch(responses: Array<Response | Error>) {
  const calls: Array<{ input: string; init: RequestInit }> = []
  const fetch: ProbeFetch = async (input, init) => {
    calls.push({ input, init })
    const response = responses.shift()
    if (!response) throw new Error('No scripted response')
    if (response instanceof Error) throw response
    return response
  }
  return { fetch, calls }
}

describe('testServerConnection', () => {
  test('checks the health marker and GraphQL status with the expected requests', async () => {
    const { fetch, calls } = scriptedFetch([health(), new Response(null, { status: 200 })])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'connected' })
    expect(calls).toHaveLength(2)
    expect(calls.map(({ input }) => input)).toEqual([
      `${endpoint}/healthz`, `${endpoint}/graphql`,
    ])
    expect(calls[0]?.init.method).toBe('GET')
    expect(calls[0]?.init.headers).toEqual({ Accept: 'application/json' })
    expect(calls[1]?.init.method).toBe('POST')
    expect(calls[1]?.init.headers).toEqual({
      'Content-Type': 'application/json', Accept: 'application/json',
    })
    expect(calls[1]?.init.body).toBe('{"query":"{ __typename }"}')
  })

  test('reports a saved key by presence without putting either server key on the request', async () => {
    const values = new Map([
      [serverCredentialKey(endpoint), 'token-for-notes'],
      [serverCredentialKey('https://other.example'), 'token-for-other'],
    ])
    const storage = { getItem: (key: string) => values.get(key) ?? null }
    const { fetch, calls } = scriptedFetch([health(), new Response(null, { status: 401 })])
    expect(await testServerConnection(endpoint, { fetch, storage }))
      .toEqual({ kind: 'auth-required', savedCredential: true })
    expect([...values.keys()]).toContain(serverCredentialKey(endpoint))
    expect(calls.every(({ init }) => !new Headers(init.headers).has('Authorization'))).toBe(true)
    expect(JSON.stringify(calls)).not.toContain('token-for-notes')
    expect(JSON.stringify(calls)).not.toContain('token-for-other')
  })

  test('reports no saved key when storage is empty', async () => {
    const { fetch } = scriptedFetch([health(), new Response(null, { status: 401 })])
    expect(await testServerConnection(endpoint, { fetch, storage: { getItem: () => null } }))
      .toEqual({ kind: 'auth-required', savedCredential: false })
  })

  test('maps other GraphQL statuses to server error', async () => {
    const { fetch } = scriptedFetch([health(), new Response(null, { status: 503 })])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'server-error', status: 503 })
  })

  test('stops after a non-200 health check', async () => {
    const { fetch, calls } = scriptedFetch([new Response(null, { status: 404 })])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'not-kaiba' })
    expect(calls).toHaveLength(1)
  })

  test('rejects an invalid JSON health response as not-kaiba', async () => {
    const { fetch } = scriptedFetch([new Response('<html>', { status: 200 })])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'not-kaiba' })
  })

  test('rejects a health response for another service', async () => {
    const { fetch } = scriptedFetch([new Response(JSON.stringify({ service: 'other', status: 'ok' }), { status: 200 })])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'not-kaiba' })
  })

  test('maps a health network failure to unreachable', async () => {
    const { fetch, calls } = scriptedFetch([new TypeError('network')])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'unreachable' })
    expect(calls).toHaveLength(1)
  })

  test('maps a GraphQL network failure to unreachable', async () => {
    const { fetch } = scriptedFetch([health(), new TypeError('network')])
    expect(await testServerConnection(endpoint, { fetch })).toEqual({ kind: 'unreachable' })
  })

  test('aborts a stalled health request and returns within one second', async () => {
    const fetch: ProbeFetch = (_input, init) => new Promise((_resolve, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
    })
    const start = performance.now()
    expect(await testServerConnection(endpoint, { fetch, timeoutMs: 10 })).toEqual({ kind: 'unreachable' })
    expect(performance.now() - start).toBeLessThan(1000)
    expect(serverProbeTimeoutMs).toBe(5000)
  })

  test.each(['ftp://x', 'https://x.example/p'])('rejects invalid candidate %s before fetching', async (candidate: string) => {
    const { fetch, calls } = scriptedFetch([])
    await expect(testServerConnection(candidate, { fetch })).rejects.toThrow()
    expect(calls).toHaveLength(0)
  })

  test('uses the normalized candidate origin for both targets', async () => {
    const { fetch, calls } = scriptedFetch([health(), new Response(null, { status: 200 })])
    expect(await testServerConnection(' https://Notes.Example.com/ ', { fetch })).toEqual({ kind: 'connected' })
    expect(calls.map(({ input }) => input)).toEqual([
      'https://notes.example.com/healthz', 'https://notes.example.com/graphql',
    ])
  })
})

describe('describeServerProbe', () => {
  test('returns the pinned status sentences', () => {
    expect(describeServerProbe({ kind: 'connected' })).toBe('Connected to a kaiba server.')
    expect(describeServerProbe({ kind: 'auth-required', savedCredential: true }))
      .toBe('Kaiba server found. Sign-in required. A saved key for this server will be used after connecting.')
    expect(describeServerProbe({ kind: 'auth-required', savedCredential: false }))
      .toBe('Kaiba server found. Sign-in required. Paste an API key after connecting.')
    expect(describeServerProbe({ kind: 'server-error', status: 503 }))
      .toBe('Kaiba server found, but it answered HTTP 503.')
    expect(describeServerProbe({ kind: 'not-kaiba' }))
      .toBe('This address answered, but it is not a kaiba server.')
    expect(describeServerProbe({ kind: 'unreachable' })).toBe('The server could not be reached.')
  })
})
