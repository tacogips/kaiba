import { afterEach, describe, expect, test, vi } from 'vitest'
import { connectionModeStorageKey, localServerEndpoint, serverEndpointStorageKey, serverRequest } from './serverEndpoint'

const native = vi.hoisted(() => ({
  invoke: vi.fn(async () => 'http://127.0.0.1:54321'),
  fetch: vi.fn(async () => new Response('{}')),
}))
vi.mock('@tauri-apps/api/core', () => ({ invoke: native.invoke }))
vi.mock('@tauri-apps/plugin-http', () => ({ fetch: native.fetch }))

afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks() })

describe('native local connection', () => {
  test('starts one local service for concurrent requests and removes remote credentials', async () => {
    vi.stubGlobal('__TAURI_INTERNALS__', {})
    vi.stubGlobal('localStorage', { getItem: () => null, setItem: vi.fn(), removeItem: vi.fn() })
    await Promise.all([localServerEndpoint(), localServerEndpoint()])
    await serverRequest('/graphql', { headers: { Authorization: 'Bearer remote-secret' } })
    expect(native.invoke).toHaveBeenCalledTimes(1)
    expect(native.fetch).toHaveBeenCalledWith('http://127.0.0.1:54321/graphql', expect.anything())
    for (const call of vi.mocked(native.fetch).mock.calls as unknown as Array<[string, RequestInit]>) {
      expect(new Headers(call[1].headers).has('Authorization')).toBe(false)
    }
  })

  test('remote mode does not start the local service and keeps the selected origin', async () => {
    vi.stubGlobal('__TAURI_INTERNALS__', {})
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => key === connectionModeStorageKey ? 'remote'
        : key === serverEndpointStorageKey ? 'https://notes.example.com' : null,
      setItem: vi.fn(), removeItem: vi.fn(),
    })
    await serverRequest('/graphql', { headers: { Authorization: 'Bearer remote-secret' } })
    expect(native.invoke).not.toHaveBeenCalled()
    expect(native.fetch).toHaveBeenCalledWith('https://notes.example.com/graphql', {
      headers: { Authorization: 'Bearer remote-secret' },
    })
  })
})
