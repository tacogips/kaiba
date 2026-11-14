import { render } from 'solid-js/web'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import { AppStoreProvider } from '../state/appStore'
import { ChatbookView } from './ChatbookView'

// An auth-required host must not render the reader shell without a credential:
// an empty tree reads as an empty store, and the Retry button would resend the
// same rejected request forever.

function client(overrides: Partial<Record<string, unknown>>): NoteGraphQLClient {
  return {
    initialize: async () => undefined,
    streamHeaders: () => ({}),
    appSetting: async () => undefined,
    notes: async () => [],
    agentModels: async () => ({ models: [], configuredModel: '' }),
    useCredential: () => undefined,
    clearCredential: () => undefined,
    hasCredential: () => false,
    ...overrides,
  } as unknown as NoteGraphQLClient
}

function unauthorized(): NoteGraphQLClient {
  const reject = () => Promise.reject(new NoteTransportError('note API requires a bearer token', 'http', 401))
  return client({ tags: reject, tagClasses: reject, notebooks: reject, appSetting: reject })
}

function open(): NoteGraphQLClient {
  return client({ tags: async () => [], tagClasses: async () => [], notebooks: async () => [] })
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 4; tick += 1) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  }
}

let originalFetch: typeof fetch

beforeEach(() => {
  // The note-events feed polls on mount; keep it off the network and idle.
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('ChatbookView authentication surface', () => {
  test('replaces the reader shell with the login view on 401', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => (
      <AppStoreProvider options={{ client: unauthorized() }}>
        <ChatbookView />
      </AppStoreProvider>
    ), host)
    try {
      await settle()
      expect(host.querySelector('.login-view')).not.toBeNull()
      expect(host.querySelector('.chatbook')).toBeNull()
      expect(host.querySelector('.chatbook-grid')).toBeNull()
      expect(host.textContent).not.toContain('No notebooks yet')
      expect(host.querySelector('.error-banner')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  test('renders the shell and no login view when the API accepts the client', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => (
      <AppStoreProvider options={{ client: open() }}>
        <ChatbookView />
      </AppStoreProvider>
    ), host)
    try {
      await settle()
      expect(host.querySelector('.chatbook')).not.toBeNull()
      expect(host.querySelector('.login-view')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  test('switches the active mobile workspace without stacking panes', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => (
      <AppStoreProvider options={{ client: open() }}>
        <ChatbookView />
      </AppStoreProvider>
    ), host)
    try {
      await settle()
      const grid = host.querySelector<HTMLElement>('.chatbook-grid')
      const nav = host.querySelector<HTMLElement>('nav[aria-label="Mobile workspace"]')
      const buttons = nav?.querySelectorAll<HTMLButtonElement>('button')

      expect(grid?.dataset.mobilePane).toBe('reader')
      expect(buttons).toHaveLength(3)
      expect(buttons?.[1]?.getAttribute('aria-current')).toBe('page')

      buttons?.[0]?.click()
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
      expect(grid?.dataset.mobilePane).toBe('files')
      expect(buttons?.[0]?.getAttribute('aria-current')).toBe('page')

      buttons?.[2]?.click()
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
      expect(grid?.dataset.mobilePane).toBe('details')
      expect(buttons?.[2]?.getAttribute('aria-current')).toBe('page')
    } finally {
      dispose()
      host.remove()
    }
  })
})
