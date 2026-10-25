import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { createComponent } from 'solid-js'
import { render } from 'solid-js/web'
import {
  serverCredentialKey,
  serverEndpointStorageKey,
  connectionModeStorageKey,
  recentServerEndpointsStorageKey,
} from '../notes/serverEndpoint'
import { ServerConnectionSettings } from './ServerConnectionSettings'

const invoke = vi.hoisted(() => vi.fn(async () => 'http://127.0.0.1:54321'))
const http = vi.hoisted(() => ({ fetch: vi.fn() }))
vi.mock('@tauri-apps/api/core', () => ({ invoke }))
vi.mock('@tauri-apps/plugin-http', () => ({ fetch: http.fetch }))

/** happy-dom does not provide localStorage here, and the component reads and
 * writes it through the endpoint module, so the suite installs an in-memory
 * store with the same surface. */
function installStorage(): Storage {
  const values = new Map<string, string>()
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value) },
    removeItem: (key: string) => { values.delete(key) },
    clear: () => { values.clear() },
    key: (index: number) => [...values.keys()][index] ?? null,
    get length() { return values.size },
  } as Storage
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: storage })
  return storage
}

/** The form renders only in a native runtime, so the Tauri marker has to be on
 * the global before the component is created. */
function withTauriRuntime(): () => void {
  const global = globalThis as { __TAURI_INTERNALS__?: unknown }
  global.__TAURI_INTERNALS__ = {}
  return () => { delete global.__TAURI_INTERNALS__ }
}

function reloadSpy(): { count: () => number; restore: () => void } {
  const original = window.location.reload
  let calls = 0
  Object.defineProperty(window.location, 'reload', {
    configurable: true,
    value: () => { calls += 1 },
  })
  return {
    count: () => calls,
    restore: () => {
      Object.defineProperty(window.location, 'reload', { configurable: true, value: original })
    },
  }
}

/** Solid delegates `input` from the document, so the container has to be in
 * the document for the field to update before submit. */
function mount(): HTMLElement {
  const container = document.createElement('div')
  document.body.appendChild(container)
  return container
}

function submit(container: HTMLElement, value: string): void {
  const input = container.querySelector('input') as HTMLInputElement
  input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
  const form = container.querySelector('form') as HTMLFormElement
  form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
}

describe('ServerConnectionSettings', () => {
  let dropTauri: () => void

  beforeEach(() => {
    installStorage()
    dropTauri = withTauriRuntime()
    http.fetch.mockReset()
  })

  afterEach(() => { dropTauri() })

  test('renders nothing at all outside a native runtime, chrome included', () => {
    dropTauri()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    // Not just the form: the Config screen's section and heading must be absent
    // too, or the browser client shows an empty bordered card.
    expect(container.querySelector('form')).toBeNull()
    expect(container.querySelector('section.config-section')).toBeNull()
    expect(container.textContent).not.toContain('Server connection')
    expect(container.innerHTML).toBe('')
    dispose()
    container.remove()
  })

  test('supplies its own Config section chrome in a native runtime', () => {
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    const section = container.querySelector('section.config-section')
    expect(section).not.toBeNull()
    expect(section?.querySelector('h2')?.textContent).toBe('Server connection')
    expect(section?.querySelector('form')).not.toBeNull()
    dispose()
    container.remove()
  })

  test('renders the compact login variant without the section chrome', () => {
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, { compact: true }), container)
    expect(container.querySelector('section.config-section')).toBeNull()
    expect(container.querySelector('form.compact')).not.toBeNull()
    dispose()
    container.remove()
  })

  test('keeps each origin credential under its own key across a switch and back', async () => {
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
    localStorage.setItem(serverCredentialKey('https://notes.example.com'), 'bearer-issued-by-notes')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)

    // A mistyped origin: valid enough to save, so it must not cost the credential.
    submit(container, 'https://notes.exmaple.com')
    await vi.waitFor(() => expect(reload.count()).toBe(1))
    expect(localStorage.getItem(serverEndpointStorageKey)).toBe('https://notes.exmaple.com')
    expect(localStorage.getItem(serverCredentialKey('https://notes.exmaple.com'))).toBeNull()
    expect(localStorage.getItem(serverCredentialKey('https://notes.example.com')))
      .toBe('bearer-issued-by-notes')
    expect(reload.count()).toBe(1)

    // Correcting the typo makes the original credential readable again.
    submit(container, 'https://notes.example.com')
    await vi.waitFor(() => expect(reload.count()).toBe(2))
    expect(localStorage.getItem(serverCredentialKey('https://notes.example.com')))
      .toBe('bearer-issued-by-notes')
    expect(reload.count()).toBe(2)

    dispose()
    container.remove()
    reload.restore()
  })

  test('starts local storage before switching and retains the remote URL and credential', async () => {
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
    localStorage.setItem(serverCredentialKey('https://notes.example.com'), 'remote-secret')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      const select = container.querySelector('select')!
      select.value = 'local'
      select.dispatchEvent(new Event('change', { bubbles: true }))
      expect(container.querySelector('input[type="url"]')).toBeNull()
      container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await vi.waitFor(() => expect(reload.count()).toBe(1))
      expect(invoke).toHaveBeenCalledWith('start_local_server')
      expect(localStorage.getItem(connectionModeStorageKey)).toBe('local')
      expect(localStorage.getItem(serverEndpointStorageKey)).toBe('https://notes.example.com')
      expect(localStorage.getItem(serverCredentialKey('https://notes.example.com'))).toBe('remote-secret')
    } finally {
      dispose()
      container.remove()
      reload.restore()
    }
  })

  test('renders the validation failure and neither saves nor reloads on an invalid URL', () => {
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)

    submit(container, 'https://notes.example.com/kaiba')
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('path')
    expect(localStorage.getItem(serverEndpointStorageKey)).toBe('https://notes.example.com')
    expect(reload.count()).toBe(0)

    dispose()
    container.remove()
    reload.restore()
  })

  test('shows the stored active target in full and compact forms', () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com:8443')
    const full = mount()
    const disposeFull = render(() => createComponent(ServerConnectionSettings, {}), full)
    expect(full.querySelector('.server-connection-active')?.textContent)
      .toBe('Active: Remote — notes.example.com:8443')
    disposeFull()
    full.remove()

    const compact = mount()
    const disposeCompact = render(() => createComponent(ServerConnectionSettings, { compact: true }), compact)
    expect(compact.querySelector('.server-connection-active')?.textContent)
      .toBe('Active: Remote — notes.example.com:8443')
    disposeCompact()
    compact.remove()
  })

  test('shows the local active target without remote controls', () => {
    localStorage.setItem(connectionModeStorageKey, 'local')
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    expect(container.querySelector('.server-connection-active')?.textContent).toBe('Active: Local — this Mac')
    expect(container.querySelector('[aria-label="Test connection"]')).toBeNull()
    expect(container.querySelector('[aria-label="Recent servers"]')).toBeNull()
    dispose()
    container.remove()
  })

  test('probes without credentials or storage changes and reports an existing key on 401', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
    localStorage.setItem(serverCredentialKey('https://notes.example.com'), 'own')
    localStorage.setItem(serverCredentialKey('https://other.example'), 'foreign')
    localStorage.setItem(recentServerEndpointsStorageKey, '["https://old.example"]')
    http.fetch.mockResolvedValueOnce(new Response('{"service":"kaiba","status":"ok"}', { status: 200 }))
      .mockResolvedValueOnce(new Response('', { status: 401 }))
    const before = ['kaiba-server-endpoint', connectionModeStorageKey, recentServerEndpointsStorageKey]
      .map((key) => localStorage.getItem(key))
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')!.click()
      await vi.waitFor(() => expect(container.querySelector('[role="status"]')?.textContent).toContain('Sign-in required'))
      expect(container.querySelector('[role="status"]')?.textContent).toContain('saved key')
      expect(http.fetch.mock.calls.map(([target]) => target)).toEqual([
        'https://notes.example.com/healthz', 'https://notes.example.com/graphql',
      ])
      expect(http.fetch.mock.calls.every(([, init]) => !new Headers(init.headers).has('Authorization'))).toBe(true)
      expect(['kaiba-server-endpoint', connectionModeStorageKey, recentServerEndpointsStorageKey]
        .map((key) => localStorage.getItem(key))).toEqual(before)
      expect(reload.count()).toBe(0)
    } finally {
      dispose()
      container.remove()
      reload.restore()
    }
  })

  test('reports a rejected probe as unreachable', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    http.fetch.mockRejectedValue(new Error('offline'))
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')!.click()
    await vi.waitFor(() => expect(container.querySelector('[role="status"]')?.textContent)
      .toBe('The server could not be reached.'))
    dispose()
    container.remove()
  })

  test('reports a non-kaiba health response', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    http.fetch.mockResolvedValue(new Response('{"service":"other","status":"ok"}', { status: 200 }))
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')!.click()
    await vi.waitFor(() => expect(container.querySelector('[role="status"]')?.textContent).toContain('not a kaiba server'))
    expect(http.fetch).toHaveBeenCalledTimes(1)
    dispose()
    container.remove()
  })

  test('shows probe validation errors without making a request', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'https://notes.example.com/path'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')!.click()
    await vi.waitFor(() => expect(container.querySelector('[role="status"]')?.textContent).toContain('path'))
    expect(http.fetch).not.toHaveBeenCalled()
    dispose()
    container.remove()
  })

  test('recent selection fills the URL and successful save moves it to the front', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    localStorage.setItem(recentServerEndpointsStorageKey, '["https://a.example","https://b.example"]')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      const recent = container.querySelector<HTMLSelectElement>('[aria-label="Recent servers"]')!
      recent.value = 'https://b.example'
      recent.dispatchEvent(new Event('change', { bubbles: true }))
      expect((container.querySelector('input') as HTMLInputElement).value).toBe('https://b.example')
      expect(reload.count()).toBe(0)
      container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await vi.waitFor(() => expect(reload.count()).toBe(1))
      expect(JSON.parse(localStorage.getItem(recentServerEndpointsStorageKey)!))
        .toEqual(['https://b.example', 'https://a.example'])
    } finally {
      dispose()
      container.remove()
      reload.restore()
    }
  })

  test('records a first remote save even when no recent picker was initially shown', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      expect(container.querySelector('[aria-label="Recent servers"]')).toBeNull()
      submit(container, 'https://notes.example.com/')
      await vi.waitFor(() => expect(reload.count()).toBe(1))
      expect(JSON.parse(localStorage.getItem(recentServerEndpointsStorageKey)!)).toEqual(['https://notes.example.com'])
    } finally {
      dispose()
      container.remove()
      reload.restore()
    }
  })

  test('local and invalid saves do not record recent endpoints', () => {
    localStorage.setItem(connectionModeStorageKey, 'local')
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    expect(localStorage.getItem(recentServerEndpointsStorageKey)).toBeNull()
    dispose()
    container.remove()

    localStorage.setItem(connectionModeStorageKey, 'remote')
    const invalid = mount()
    const disposeInvalid = render(() => createComponent(ServerConnectionSettings, {}), invalid)
    submit(invalid, 'https://notes.example.com/path')
    expect(localStorage.getItem(recentServerEndpointsStorageKey)).toBeNull()
    disposeInvalid()
    invalid.remove()
  })

  test('does not record a remote endpoint when saving the mode fails', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    const originalSetItem = localStorage.setItem.bind(localStorage)
    Object.defineProperty(localStorage, 'setItem', {
      configurable: true,
      value: (key: string, value: string) => {
        if (key === connectionModeStorageKey) throw new Error('mode save failed')
        originalSetItem(key, value)
      },
    })
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      submit(container, 'https://notes.example.com')
      await vi.waitFor(() => expect(container.querySelector('[role="alert"]')?.textContent).toContain('mode save failed'))
      expect(localStorage.getItem(recentServerEndpointsStorageKey)).toBeNull()
      expect(reload.count()).toBe(0)
    } finally {
      dispose()
      container.remove()
      reload.restore()
      Object.defineProperty(localStorage, 'setItem', { configurable: true, value: originalSetItem })
    }
  })

  test('still reloads after successful save if recent history cannot be stored', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    const originalSetItem = localStorage.setItem.bind(localStorage)
    Object.defineProperty(localStorage, 'setItem', {
      configurable: true,
      value: (key: string, value: string) => {
        if (key === recentServerEndpointsStorageKey) throw new Error('quota exceeded')
        originalSetItem(key, value)
      },
    })
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      submit(container, 'https://notes.example.com')
      await vi.waitFor(() => expect(reload.count()).toBe(1))
      expect(localStorage.getItem(serverEndpointStorageKey)).toBe('https://notes.example.com')
      expect(container.querySelector('[role="alert"]')).toBeNull()
    } finally {
      dispose()
      container.remove()
      reload.restore()
      Object.defineProperty(localStorage, 'setItem', { configurable: true, value: originalSetItem })
    }
  })

  test('warns reactively for plain remote HTTP and still saves it', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    try {
      const input = container.querySelector('input') as HTMLInputElement
      input.value = 'http://192.168.1.20:8787'
      input.dispatchEvent(new Event('input', { bubbles: true }))
      expect(container.querySelector('.server-connection-warning')?.textContent)
        .toBe('This server uses plain HTTP; the API key travels unencrypted.')
      container.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await vi.waitFor(() => expect(reload.count()).toBe(1))
      expect(localStorage.getItem(serverEndpointStorageKey)).toBe('http://192.168.1.20:8787')
      input.value = 'http://127.0.0.1:8787'
      input.dispatchEvent(new Event('input', { bubbles: true }))
      expect(container.querySelector('.server-connection-warning')).toBeNull()
      input.value = 'https://192.168.1.20'
      input.dispatchEvent(new Event('input', { bubbles: true }))
      expect(container.querySelector('.server-connection-warning')).toBeNull()
    } finally {
      dispose()
      container.remove()
      reload.restore()
    }
  })

  test('clears an in-flight probe result when the endpoint changes', async () => {
    localStorage.setItem(connectionModeStorageKey, 'remote')
    let resolveHealth!: (response: Response) => void
    http.fetch.mockImplementationOnce(() => new Promise<Response>((resolve) => { resolveHealth = resolve }))
      .mockResolvedValue(new Response('{"service":"kaiba","status":"ok"}', { status: 200 }))
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')!.click()
    await vi.waitFor(() => expect(http.fetch).toHaveBeenCalledTimes(1))
    const input = container.querySelector('input') as HTMLInputElement
    input.value = 'https://different.example'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    expect(container.querySelector<HTMLButtonElement>('[aria-label="Test connection"]')?.disabled).toBe(false)
    resolveHealth(new Response('{"service":"kaiba","status":"ok"}', { status: 200 }))
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(container.querySelector('[role="status"]')?.textContent).toBeFalsy()
    dispose()
    container.remove()
  })
})
