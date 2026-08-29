import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { createComponent } from 'solid-js'
import { render } from 'solid-js/web'
import {
  serverCredentialKey,
  serverEndpointStorageKey,
} from '../notes/serverEndpoint'
import { ServerConnectionSettings } from './ServerConnectionSettings'

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
  })

  afterEach(() => { dropTauri() })

  test('renders nothing outside a native runtime', () => {
    dropTauri()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)
    expect(container.querySelector('form')).toBeNull()
    dispose()
    container.remove()
  })

  test('keeps each origin credential under its own key across a switch and back', () => {
    localStorage.setItem(serverEndpointStorageKey, 'https://notes.example.com')
    localStorage.setItem(serverCredentialKey('https://notes.example.com'), 'bearer-issued-by-notes')
    const reload = reloadSpy()
    const container = mount()
    const dispose = render(() => createComponent(ServerConnectionSettings, {}), container)

    // A mistyped origin: valid enough to save, so it must not cost the credential.
    submit(container, 'https://notes.exmaple.com')
    expect(localStorage.getItem(serverEndpointStorageKey)).toBe('https://notes.exmaple.com')
    expect(localStorage.getItem(serverCredentialKey('https://notes.exmaple.com'))).toBeNull()
    expect(localStorage.getItem(serverCredentialKey('https://notes.example.com')))
      .toBe('bearer-issued-by-notes')
    expect(reload.count()).toBe(1)

    // Correcting the typo makes the original credential readable again.
    submit(container, 'https://notes.example.com')
    expect(localStorage.getItem(serverCredentialKey('https://notes.example.com')))
      .toBe('bearer-issued-by-notes')
    expect(reload.count()).toBe(2)

    dispose()
    container.remove()
    reload.restore()
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
})
