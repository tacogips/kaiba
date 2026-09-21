import { render } from 'solid-js/web'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import { AppStoreProvider } from '../state/appStore'
import { CaptureView, isCapturePathname } from './CaptureView'
import { notebookId, noteId } from '../notes/ids'

// Anywhere capture (design-docs/specs/note-capture-and-entity-pages.md, F1).
// The capture page is the surface a phone opens, so the states that matter are
// the three it can be in: registered and submitting, refused by the route, and
// never registered at all.

function client(overrides: Partial<Record<string, unknown>>): NoteGraphQLClient {
  return {
    initialize: async () => undefined,
    streamHeaders: () => ({}),
    appSetting: async () => undefined,
    notes: async () => [],
    tags: async () => [],
    tagClasses: async () => [],
    notebooks: async () => [],
    agentModels: async () => ({ models: [], configuredModel: '' }),
    useCredential: () => undefined,
    clearCredential: () => undefined,
    hasCredential: () => true,
    ...overrides,
  } as unknown as NoteGraphQLClient
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 4; tick += 1) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  }
}

function mount(api: NoteGraphQLClient): { host: HTMLElement; dispose: () => void } {
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => (
    <AppStoreProvider options={{ client: api }}><CaptureView /></AppStoreProvider>
  ), host)
  return { host, dispose }
}

function type(host: HTMLElement, value: string): void {
  const textarea = host.querySelector<HTMLTextAreaElement>('#capture-text')!
  textarea.value = value
  textarea.dispatchEvent(new Event('input', { bubbles: true }))
}

let originalFetch: typeof fetch

beforeEach(() => {
  window.location.hash = ''
  // The note-events feed polls on mount; keep it off the network and idle.
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('anywhere capture page', () => {
  test('boots only on the path the server rewrites to the SPA', () => {
    expect(isCapturePathname('/note/capture')).toBe(true)
    expect(isCapturePathname('/note/capture/')).toBe(true)
    expect(isCapturePathname('/')).toBe(false)
    expect(isCapturePathname('/note/register')).toBe(false)
    expect(isCapturePathname('/note/capture/extra')).toBe(false)
  })

  test('sends the note, reports the id the server assigned, and clears for the next thought', async () => {
    const captured: string[] = []
    const { host, dispose } = mount(client({
      captureNote: async (text: string) => {
        captured.push(text)
        return { noteId: noteId('note-9'), notebookId: notebookId('notebook-quick'), noteNumber: 3 }
      },
    }))
    try {
      await settle()
      const submit = host.querySelector<HTMLButtonElement>('button[type="submit"]')!
      // Nothing to capture is not a request.
      expect(submit.disabled).toBe(true)
      type(host, 'A thought')
      expect(submit.disabled).toBe(false)
      host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await settle()
      expect(captured).toEqual(['A thought'])
      expect(host.querySelector('[role="status"]')?.textContent).toContain('note-9')
      expect(host.querySelector<HTMLTextAreaElement>('#capture-text')!.value).toBe('')
      expect(host.querySelector('[role="alert"]')).toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('renders the route error body and keeps the text the capture failed on', async () => {
    const { host, dispose } = mount(client({
      captureNote: async () => {
        throw new NoteTransportError('quick memo could not be captured', 'http', 500)
      },
    }))
    try {
      await settle()
      type(host, 'A thought')
      host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await settle()
      expect(host.querySelector('[role="alert"]')?.textContent).toContain('quick memo could not be captured')
      // A failed send must not lose the note: the text stays for a retry.
      expect(host.querySelector<HTMLTextAreaElement>('#capture-text')!.value).toBe('A thought')
      expect(host.querySelector('.login-form')).not.toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('falls back to the existing login surface for an unregistered visitor', async () => {
    const reject = () => Promise.reject(new NoteTransportError('note API requires a bearer token', 'http', 401))
    const { host, dispose } = mount(client({
      hasCredential: () => false,
      tags: reject, tagClasses: reject, notebooks: reject, appSetting: reject,
    }))
    try {
      await settle()
      expect(host.querySelector('#capture-text')).toBeNull()
      expect(host.querySelector('.login-view')).not.toBeNull()
      expect(host.textContent).toContain('Sign in to this note server')
    } finally { dispose(); host.remove() }
  })

  test('shows the login surface when the route refuses the stored bearer', async () => {
    const { host, dispose } = mount(client({
      captureNote: async () => {
        throw new NoteTransportError('note API bearer token is invalid or revoked', 'http', 401)
      },
    }))
    try {
      await settle()
      type(host, 'A thought')
      host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await settle()
      expect(host.querySelector('#capture-text')).toBeNull()
      expect(host.querySelector('.login-view')).not.toBeNull()
    } finally { dispose(); host.remove() }
  })
})
