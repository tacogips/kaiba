import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { render } from 'solid-js/web'
import { AppStoreProvider } from '../state/appStore'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import { connectionModeStorageKey, serverEndpointStorageKey } from '../notes/serverEndpoint'
import { ChatbookView } from './ChatbookView'

const http = vi.hoisted(() => ({ fetch: vi.fn(() => new Promise<Response>(() => undefined)) }))
const invoke = vi.hoisted(() => vi.fn(async () => 'http://127.0.0.1:54321'))
vi.mock('@tauri-apps/plugin-http', () => ({ fetch: http.fetch }))
vi.mock('@tauri-apps/api/core', () => ({ invoke }))
vi.mock('../components/UserAgentSettings', () => ({ UserAgentSettings: () => null }))
vi.mock('../components/SearchEngineSettings', () => ({ SearchEngineSettings: () => null }))

function installStorage(): void {
  const values = new Map<string, string>()
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value) },
    removeItem: (key: string) => { values.delete(key) },
    clear: () => values.clear(),
    key: (index: number) => [...values.keys()][index] ?? null,
    get length() { return values.size },
  } as Storage
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: storage })
  localStorage.setItem(connectionModeStorageKey, 'remote')
  localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
}

function clientWith(reject: () => Promise<never>): NoteGraphQLClient {
  return {
    initialize: async () => undefined,
    streamHeaders: () => ({}),
    appSetting: reject,
    tags: reject,
    tagClasses: reject,
    notebooks: reject,
    searchEngineCapability: reject,
    userAgentCredential: reject,
    searchEngineSettings: reject,
    useCredential: () => undefined,
    clearCredential: () => undefined,
    hasCredential: () => false,
  } as unknown as NoteGraphQLClient
}

function rejectedClientCall(error: NoteTransportError): () => Promise<never> {
  return () => Promise.reject(error)
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 5; tick += 1) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  }
}

beforeEach(() => {
  vi.stubGlobal('__TAURI_INTERNALS__', {})
  installStorage()
  http.fetch.mockClear()
  window.location.hash = ''
})

afterEach(() => { vi.unstubAllGlobals() })

describe('connection settings reachability', () => {
  test('opens full settings after network errors', async () => {
    const network = rejectedClientCall(new NoteTransportError('Failed to fetch', 'network'))
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: clientWith(network) }}><ChatbookView /></AppStoreProvider>, host)
    try {
      await settle()
      const settings = host.querySelector<HTMLButtonElement>('button[aria-label="Settings"]')
      expect(settings).not.toBeNull()
      settings!.click()
      await settle()
      const form = host.querySelector('.config-view form.server-connection')
      expect(form).not.toBeNull()
      expect(form?.querySelector('.server-connection-active')).not.toBeNull()
      expect(form?.querySelector('[aria-label="Test connection"]')).not.toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('shows compact connection settings after an authentication failure', async () => {
    const unauthorized = rejectedClientCall(new NoteTransportError('Unauthorized', 'http', 401))
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: clientWith(unauthorized) }}><ChatbookView /></AppStoreProvider>, host)
    try {
      await settle()
      const form = host.querySelector('.login-view form.server-connection.compact')
      expect(form).not.toBeNull()
      expect(form?.querySelector('.server-connection-active')).not.toBeNull()
    } finally { dispose(); host.remove() }
  })
})
