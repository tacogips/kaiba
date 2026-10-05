import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import type { SearchEngineSettings as Settings } from '../notes/types'
import type { AppStore } from '../state/appStore'
import { SearchEngineSettings } from './SearchEngineSettings'

const initial: Settings = {
  managedBy: 'store', kind: 'elasticsearch', url: 'https://search.example.com:9200', indexPrefix: 'kaiba',
  authMode: 'basic', username: 'admin', hasSecret: true, verifyTLS: true,
  requestTimeoutSeconds: 10, adapters: [{ kind: 'elasticsearch', displayName: 'Elasticsearch', authModes: ['none', 'basic', 'apiKey'] }], active: true,
}

function mount(settings: Settings | null, overrides: Partial<NoteGraphQLClient> = {}) {
  const saved = { ...initial }
  const client = {
    searchEngineSettings: vi.fn(async () => settings),
    updateSearchEngineSettings: vi.fn(async () => saved),
    testSearchEngineConnection: vi.fn(async () => ({ available: true, status: 'available', detail: 'green' })),
    ...overrides,
  } as unknown as Pick<NoteGraphQLClient, 'searchEngineSettings' | 'updateSearchEngineSettings' | 'testSearchEngineConnection'>
  const reloadSearchEngineCapability = vi.fn(async () => undefined)
  const app = { client, reloadSearchEngineCapability } as unknown as Pick<AppStore, 'client' | 'reloadSearchEngineCapability'>
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <SearchEngineSettings client={client} app={app} />, host)
  return { host, dispose, client, reloadSearchEngineCapability }
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
}

function inputByLabel(host: HTMLElement, text: string): HTMLInputElement {
  const label = [...host.querySelectorAll('label')].find((item) => item.textContent?.includes(text))
  return label?.querySelector('input') as HTMLInputElement
}

function memoryStorage(): Storage {
  const values = new Map<string, string>()
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => { values.set(key, value) },
    removeItem: (key) => { values.delete(key) },
    clear: () => values.clear(),
    key: (index) => [...values.keys()][index] ?? null,
    get length() { return values.size },
  } as Storage
}

function storageContains(storage: Storage, needle: string): boolean {
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index)
    if (key !== null && (key.includes(needle) || (storage.getItem(key) ?? '').includes(needle))) return true
  }
  return false
}

describe('SearchEngineSettings', () => {
  test('renders nothing when settings are not accepted', async () => {
    const view = mount(null)
    try {
      await settle()
      expect(view.host.innerHTML).toBe('')
    } finally { view.dispose(); view.host.remove() }
  })

  test('shows config-managed settings read-only without actions', async () => {
    const view = mount({ ...initial, managedBy: 'config' })
    try {
      await settle()
      expect(view.host.textContent).toContain('Managed by the server configuration file')
      expect(view.host.querySelector('button')).toBeNull()
    } finally { view.dispose(); view.host.remove() }
  })

  test('disables Save for an invalid URL', async () => {
    const view = mount({ ...initial, hasSecret: false })
    try {
      await settle()
      const url = inputByLabel(view.host, 'URL')
      url.value = 'http://example.com'
      url.dispatchEvent(new Event('input', { bubbles: true }))
      expect(view.host.querySelector<HTMLButtonElement>('button[type="submit"]')?.disabled).toBe(true)
    } finally { view.dispose(); view.host.remove() }
  })

  test('shows sanitized test status and detail as text', async () => {
    const view = mount(initial)
    try {
      await settle()
      view.host.querySelector<HTMLButtonElement>('button[type="button"]')?.click()
      await settle()
      expect(view.host.querySelector('[role="status"]')?.textContent).toBe('available: green')
    } finally { view.dispose(); view.host.remove() }
  })

  test('saves a write-only secret, clears the input and reloads capability', async () => {
    const oldLocalStorage = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
    const oldSessionStorage = Object.getOwnPropertyDescriptor(globalThis, 'sessionStorage')
    Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: memoryStorage() })
    Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: memoryStorage() })
    const view = mount({ ...initial, hasSecret: false })
    try {
      await settle()
      const secret = inputByLabel(view.host, 'Secret')
      secret.value = 'p20-secret-value'
      secret.dispatchEvent(new Event('input', { bubbles: true }))
      view.host.querySelector<HTMLButtonElement>('button[type="submit"]')?.click()
      await vi.waitFor(() => expect(view.client.updateSearchEngineSettings).toHaveBeenCalled())
      expect(view.client.updateSearchEngineSettings).toHaveBeenCalledWith(expect.objectContaining({ secret: 'p20-secret-value' }))
      await vi.waitFor(() => expect(view.reloadSearchEngineCapability).toHaveBeenCalledTimes(1))
      expect(inputByLabel(view.host, 'Secret').value).toBe('')
      expect(storageContains(localStorage, 'p20-secret-value')).toBe(false)
      expect(storageContains(sessionStorage, 'p20-secret-value')).toBe(false)
      expect(view.host.innerHTML).not.toContain('p20-secret-value')
    } finally {
      view.dispose()
      view.host.remove()
      if (oldLocalStorage) Object.defineProperty(globalThis, 'localStorage', oldLocalStorage)
      else Reflect.deleteProperty(globalThis, 'localStorage')
      if (oldSessionStorage) Object.defineProperty(globalThis, 'sessionStorage', oldSessionStorage)
      else Reflect.deleteProperty(globalThis, 'sessionStorage')
    }
  })

  test('uses only the authentication modes declared by the Meilisearch descriptor', async () => {
    const settings: Settings = {
      ...initial,
      hasSecret: false,
      adapters: [
        { kind: 'elasticsearch', displayName: 'Elasticsearch', authModes: ['none', 'basic', 'apiKey'] },
        { kind: 'meilisearch', displayName: 'Meilisearch', authModes: ['none', 'apiKey'] },
      ],
    }
    const view = mount(settings)
    try {
      await settle()
      const engine = view.host.querySelector<HTMLSelectElement>('label select')
      expect(engine).not.toBeNull()
      engine!.value = 'meilisearch'
      engine!.dispatchEvent(new Event('change', { bubbles: true }))

      const url = inputByLabel(view.host, 'URL')
      url.value = 'http://127.0.0.1:7700'
      url.dispatchEvent(new Event('input', { bubbles: true }))

      const authMode = [...view.host.querySelectorAll('label')]
        .find((label) => label.textContent?.includes('Authentication'))
        ?.querySelector<HTMLSelectElement>('select')
      expect([...authMode!.options].map((option) => option.value)).toEqual(['none', 'apiKey'])
      expect(inputByLabel(view.host, 'Username')).toBeFalsy()

      authMode!.value = 'apiKey'
      authMode!.dispatchEvent(new Event('change', { bubbles: true }))
      const secret = inputByLabel(view.host, 'Secret')
      expect(secret.type).toBe('password')
      expect(inputByLabel(view.host, 'Username')).toBeFalsy()
      secret.value = 'meilisearch-test-key'
      secret.dispatchEvent(new Event('input', { bubbles: true }))
      view.host.querySelector<HTMLButtonElement>('button[type="submit"]')?.click()

      await vi.waitFor(() => expect(view.client.updateSearchEngineSettings).toHaveBeenCalled())
      const input = vi.mocked(view.client.updateSearchEngineSettings).mock.calls.at(0)?.[0]
      expect(input).toMatchObject({ kind: 'meilisearch', url: 'http://127.0.0.1:7700', authMode: 'apiKey' })
      expect(input).not.toHaveProperty('username')
    } finally { view.dispose(); view.host.remove() }
  })

  test('storage scan detects a secret persisted as a value under an ordinary key', () => {
    const storage = memoryStorage()
    storage.setItem('kaiba.searchEngineForm', JSON.stringify({ secret: 'p20-secret-value' }))
    expect(storageContains(storage, 'p20-secret-value')).toBe(true)
  })

  test('requires a new secret before testing or saving a changed target', async () => {
    const view = mount(initial)
    try {
      await settle()
      const url = inputByLabel(view.host, 'URL')
      url.value = 'https://other.example.com:9200'
      url.dispatchEvent(new Event('input', { bubbles: true }))
      expect(inputByLabel(view.host, 'Secret').required).toBe(true)
      expect(view.host.querySelectorAll('button').length).toBe(2)
      expect([...view.host.querySelectorAll<HTMLButtonElement>('button')].every((button) => button.disabled)).toBe(true)
      expect(view.client.testSearchEngineConnection).not.toHaveBeenCalled()
      expect(view.client.updateSearchEngineSettings).not.toHaveBeenCalled()
    } finally { view.dispose(); view.host.remove() }
  })
})
