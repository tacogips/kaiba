import { render } from 'solid-js/web'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import { AppStoreProvider } from '../state/appStore'
import { ChatbookView } from './ChatbookView'
import { notebookId, noteId, commentId } from '../notes/ids'
import { homeRoute } from '../router'

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
  window.location.hash = ''
  // The note-events feed polls on mount; keep it off the network and idle.
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('ChatbookView authentication surface', () => {
  test('reveals a footer conversation from Settings with asynchronous hash navigation', async () => {
    let hash = '#/config'
    const listeners = new Set<() => void>()
    const router = {
      currentHash: () => hash,
      setHash: (next: string) => {
        hash = next
        window.setTimeout(() => { for (const listener of listeners) listener() }, 0)
      },
      addListener: (listener: () => void) => { listeners.add(listener) },
      removeListener: (listener: () => void) => { listeners.delete(listener) },
    }
    const api = client({
      tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
      userAgentCredential: async () => ({ featureEnabled: true, credential: null, providers: ['codex'] }),
      notebook: async () => ({ notebookId: notebookId('chat'), type: 'AGENT_CHAT', tags: [], readOnly: false }),
      notebookComments: async () => [], notebookConversations: async () => [],
      sendAgentChatMessage: async () => ({ conversationNotebookId: notebookId('chat'), agentStatus: 'pending' }),
    })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: api, router }}>
      <ChatbookView />
    </AppStoreProvider>, host)
    try {
      await settle()
      host.querySelector<HTMLButtonElement>('button[aria-label="Ask AI"]')!.click()
      await settle()
      const textarea = host.querySelector<HTMLTextAreaElement>('textarea[aria-label="Ask AI anything"]')!
      textarea.value = 'Hello'
      textarea.dispatchEvent(new Event('input', { bubbles: true }))
      host.querySelector('footer form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await settle()
      expect(hash).toBe('#/')
      expect(host.querySelector('.pane-right .chat')).not.toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('shortcut destinations survive asynchronous native-style hash navigation', async () => {
    let hash = '#/config'
    const listeners = new Set<() => void>()
    const router = {
      currentHash: () => hash,
      setHash: (next: string) => {
        hash = next
        window.setTimeout(() => { for (const listener of listeners) listener() }, 0)
      },
      addListener: (listener: () => void) => { listeners.add(listener) },
      removeListener: (listener: () => void) => { listeners.delete(listener) },
    }
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: client({ tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
      userAgentCredential: async () => ({ featureEnabled: false, credential: null, providers: [] }),
    }), router }}><ChatbookView /></AppStoreProvider>, host)
    const key = (key: string, shiftKey = false) => window.dispatchEvent(new KeyboardEvent('keydown', {
      key, shiftKey, metaKey: true, cancelable: true,
    }))
    try {
      await settle()
      key('n')
      await settle()
      expect(document.activeElement).toBe(host.querySelector('.new-notebook-editor textarea'))
      key(',')
      await settle()
      key('t', true)
      await settle()
      expect(host.querySelector('.notebook-timeline')).not.toBeNull()
      expect(host.querySelector<HTMLElement>('.chatbook-grid')?.dataset.mobilePane).toBe('files')
      key(',')
      await settle()
      key('2', true)
      await settle()
      expect(host.querySelector('#right-tab-info')?.getAttribute('aria-selected')).toBe('true')
      expect(host.querySelector<HTMLElement>('.chatbook-grid')?.dataset.mobilePane).toBe('details')
    } finally { dispose(); host.remove() }
  })

  test('keyboard commands navigate, preserve drafts, focus AI, and respect dialogs and IME', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: open() }}><ChatbookView /></AppStoreProvider>, host)
    const key = (key: string, options: KeyboardEventInit = {}) => {
      const event = new KeyboardEvent('keydown', { key, metaKey: true, bubbles: true, cancelable: true, ...options })
      ;(document.activeElement ?? window).dispatchEvent(event)
      return event
    }
    try {
      await settle()
      const draft = host.querySelector<HTMLTextAreaElement>('.new-notebook-editor textarea')!
      draft.value = 'Keep this draft'
      draft.dispatchEvent(new Event('input', { bubbles: true }))
      draft.focus()
      expect(key('t', { shiftKey: true }).defaultPrevented).toBe(true)
      expect(host.querySelector('[aria-label="Notebook timeline"]')).not.toBeNull()
      expect(key('t', { shiftKey: true, isComposing: true }).defaultPrevented).toBe(false)
      expect(host.querySelector('[aria-label="Notebook timeline"]')).not.toBeNull()
      key('t', { shiftKey: true, repeat: true })
      expect(host.querySelector('[aria-label="Notebook timeline"]')).not.toBeNull()
      key(',')
      key('n')
      await settle()
      expect(host.querySelector<HTMLTextAreaElement>('.new-notebook-editor textarea')?.value).toBe('Keep this draft')
      expect(document.activeElement).toBe(host.querySelector('.new-notebook-editor textarea'))
      key('j')
      await settle()
      expect(document.activeElement).toBe(host.querySelector('.agent-footer textarea'))
      key('@', { code: 'Digit2', shiftKey: true, metaKey: false, ctrlKey: true })
      expect(host.querySelector('#right-tab-info')?.getAttribute('aria-selected')).toBe('true')
      key('p')
      expect(host.querySelector('[role="dialog"]')).not.toBeNull()
      expect(key('n').defaultPrevented).toBe(false)
    } finally { dispose(); host.remove() }
  })

  test('saves a note and stages a learning prompt without sending it', async () => {
    let hash = '#/'
    const listeners = new Set<() => void>()
    const router = {
      currentHash: () => hash,
      setHash: (next: string) => { hash = next; for (const listener of listeners) listener() },
      addListener: (listener: () => void) => { listeners.add(listener) },
      removeListener: (listener: () => void) => { listeners.delete(listener) },
    }
    const folder = { tagId: 'research', name: 'Research', classId: 'folder' }
    const notebook = { type: 'DOCUMENT', notebookId: notebookId('learning'), title: 'Neural networks',
      readOnly: false, createdAt: '2026-09-07', updatedAt: '2026-09-07', tags: [{ tag: folder, deletable: true }] }
    const note = { noteId: noteId('first-note'), notebookId: notebook.notebookId, noteNumber: 1,
      title: 'My first thought', bodyMarkdown: 'How does a neuron learn?', readOnly: false,
      createdAt: '2026-09-07', updatedAt: '2026-09-07', tags: [] }
    let created = true
    let saved = false
    let attempts = 0
    let finishSave: (() => void) | undefined
    let sent = 0
    const api = client({
      tags: async () => [folder], tagClasses: async () => [], notebooks: async () => created ? [notebook] : [],
      notebook: async () => notebook, note: async () => note,
      notes: async () => saved ? [note] : [], noteFiles: async () => [],
      noteComments: async () => [], notebookComments: async () => [],
      noteConversations: async () => [], notebookConversations: async () => [],
      createNotebook: async (title: string) => { expect(title).toBe('Neural networks'); created = true; return notebook },
      createNote: async (id: string, body: string) => {
        expect(id).toBe('learning'); expect(body).toBe(note.bodyMarkdown)
        attempts += 1
        if (attempts === 1) throw new Error('Connection lost')
        await new Promise<void>((resolve) => { finishSave = resolve })
        saved = true
        return note
      },
      sendAgentChatMessage: async () => { sent += 1 },
      searchNotes: async () => [{ note, snippet: note.bodyMarkdown, rank: 1, termCoverage: 1, isLinkedNeighbor: false, matchedTags: [] }],
    })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: api, router }}><ChatbookView /></AppStoreProvider>, host)
    const button = (label: string) => Array.from(host.querySelectorAll('button')).find((item) => (item.getAttribute('aria-label') ?? item.textContent) === label)!
    try {
      await settle()
      router.setHash('#/notebook/learning')
      await settle()
      expect(hash).toBe('#/notebook/learning')
      expect(host.querySelector('.pane-left [role="tree"]')?.textContent).toContain(notebook.title)
      const draft = host.querySelector<HTMLTextAreaElement>('.note-capture textarea')!
      draft.value = note.bodyMarkdown
      draft.dispatchEvent(new Event('input', { bubbles: true }))
      const save = () => host.querySelector('.note-capture form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      save()
      await settle()
      expect(draft.value).toBe(note.bodyMarkdown)
      expect(host.querySelector('.note-capture [role="alert"]')?.textContent).toContain('Connection lost')
      router.setHash('#/')
      expect(host.querySelector('.new-notebook-editor textarea')).not.toBeNull()
      button('Notebooks').click()
      expect(host.querySelector<HTMLElement>('.chatbook-grid')?.dataset.mobilePane).toBe('files')
      const notebookLink = Array.from(host.querySelectorAll<HTMLButtonElement>('.pane-left .tree-label'))
        .find((item) => item.textContent?.includes(notebook.title))!
      notebookLink.click()
      await settle()
      expect(host.querySelector<HTMLTextAreaElement>('.note-capture textarea')?.value).toBe(note.bodyMarkdown)
      save()
      await settle()
      expect(finishSave).toBeDefined()
      router.setHash('#/search?q=neuron&scope=all&method=grep')
      finishSave!()
      await settle()
      expect(hash).toBe('#/search?q=neuron&scope=all&method=grep')
      host.querySelector<HTMLButtonElement>('.search-result')!.click()
      await settle()
      expect(hash).toBe('#/note/first-note')
      expect(host.querySelector('.reader-note')?.textContent).toContain(note.bodyMarkdown)
      button('Quiz me').click()
      expect(host.querySelector<HTMLTextAreaElement>('.chat textarea')?.value).toContain('Ask one question at a time')
      expect(sent).toBe(0)
      host.querySelector<HTMLButtonElement>('.pane-right .pane-fold')!.click()
      host.querySelector<HTMLButtonElement>('.pane-right .rail-button')!.click()
      expect(host.querySelector<HTMLTextAreaElement>('.chat textarea')?.value).toContain('Ask one question at a time')
      expect(host.querySelector('.learning-context')?.textContent).toContain(note.title)
      host.querySelector<HTMLElement>('.reader-note')!.click()
      expect(hash).toBe('#/note/first-note')
      button('Notebook context').click()
      await settle()
      expect(hash).toBe('#/notebook/learning')
      host.querySelector<HTMLButtonElement>('.study-note-button')!.click()
      expect(host.querySelector<HTMLElement>('.chatbook-grid')?.dataset.mobilePane).toBe('details')
      expect(hash).toBe('#/note/first-note')
      router.setHash('#/search?q=neuron&scope=all&method=grep')
      await settle()
      const searchRoute = hash
      host.querySelector<HTMLButtonElement>('.search-result')!.click()
      await settle()
      expect(hash).toBe('#/note/first-note')
      expect(host.querySelector<HTMLElement>('.chatbook-grid')?.dataset.mobilePane).toBe('reader')
      host.querySelector<HTMLButtonElement>('.reader-back')!.click()
      await settle()
      expect(hash).toBe(searchRoute)
      expect(host.querySelector('.search-result')?.textContent).toContain(note.bodyMarkdown)
      expect(homeRoute).toEqual({ kind: 'home' })
    } finally { dispose(); host.remove() }
  })

  test('opens a plain memo as a chat notebook, continues it, and returns to the source', async () => {
    let hash = '#/note/source-note'
    const listeners = new Set<() => void>()
    const router = {
      currentHash: () => hash,
      setHash: (next: string) => { hash = next; for (const listener of listeners) listener() },
      addListener: (listener: () => void) => { listeners.add(listener) },
      removeListener: (listener: () => void) => { listeners.delete(listener) },
    }
    const source = {
      noteId: noteId('source-note'), notebookId: notebookId('source'), noteNumber: 1,
      title: 'Source note', bodyMarkdown: 'Source text', readOnly: false,
      createdAt: '2026-01-01', updatedAt: '2026-01-01', tags: [],
    }
    const memo = {
      type: 'AGENT_CHAT',
      notebookId: notebookId('memo'), title: 'Saved thought', readOnly: false,
      createdAt: '2026-01-01', updatedAt: '2026-01-01',
      tags: [{ tag: { tagId: 'kind', name: 'notebook-kind:agent-conversation', isSystem: true }, deletable: false }],
    }
    const memoTurn = {
      ...source, noteId: noteId('memo-turn'), notebookId: memo.notebookId,
      bodyMarkdown: 'Saved thought',
      metaJSON: JSON.stringify({ kaibaChat: { status: 'answered', userMarkdown: 'Saved thought', memoOnly: true } }),
    }
    const sent: Array<Record<string, unknown>> = []
    const api = client({
      tags: async () => [], tagClasses: async () => [],
      notebooks: async () => [{ ...memo, type: 'DOCUMENT', notebookId: source.notebookId, title: 'Source notebook', tags: [] }],
      notebook: async () => memo,
      note: async () => source,
      noteFiles: async () => [],
      notes: async (id: string) => id === 'memo' ? [memoTurn] : [source],
      noteComments: async () => [{ commentId: commentId('memo-comment'), noteId: source.noteId,
        notebookId: source.notebookId, bodyMarkdown: 'Saved thought', author: 'user', createdAt: '2026-01-01' }],
      notebookComments: async () => [], noteConversations: async () => [], notebookConversations: async () => [],
      openMemoNotebook: async () => memo,
      sendAgentChatMessage: async (request: Record<string, unknown>) => {
        sent.push(request)
        return { conversationNotebookId: memo.notebookId, turnNoteId: null, agentStatus: 'answered' }
      },
    })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client: api, router }}>
      <ChatbookView />
    </AppStoreProvider>, host)
    try {
      await settle()
      const open = Array.from(host.querySelectorAll('button')).find((button) => button.textContent === 'Open as notebook')
      expect(open).toBeDefined()
      open!.click()
      await settle()
      expect(hash).toBe('#/notebook/memo')
      const chat = host.querySelector('main .chat')!
      expect(chat).not.toBeNull()
      expect(chat.textContent).toContain('Saved thought')
      expect(chat.textContent).not.toContain('No reply yet')
      const composer = chat.querySelector('textarea')!
      composer.value = 'Discuss this thought'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle()
      expect(sent[0]?.conversationNotebookId).toBe('memo')
      expect(sent[0]?.subjectNotebookId).toBeUndefined()
      host.querySelector<HTMLButtonElement>('.reader-back')!.click()
      await settle()
      expect(hash).toBe('#/note/source-note')
      expect(host.querySelector('main')?.textContent).toContain('Source text')
    } finally { dispose(); host.remove() }
  })

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
      expect(host.querySelector('main [role="tablist"]')).toBeNull()
      expect(host.querySelector('main .notebook-list-view')).toBeNull()
      expect(host.querySelector('.pane-left [role="tree"]')).not.toBeNull()
      expect(host.querySelector('.pane-left .notebook-create')).toBeNull()
      expect(host.querySelector('.new-notebook-editor textarea')).not.toBeNull()
      host.querySelector<HTMLButtonElement>('[aria-label="Links"]')!.click()
      expect(host.querySelector('#right-tab-links')?.getAttribute('aria-selected')).toBe('true')
      host.querySelector<HTMLButtonElement>('[aria-label="AI"]')!.click()
      expect(host.querySelector('#right-tab-memo')?.getAttribute('aria-selected')).toBe('true')
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'p', metaKey: true, cancelable: true }))
      expect(host.querySelector('[role="dialog"]')).not.toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  test('warns before discarding a draft and makes a cancelled notebook draft discoverable', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => (
      <AppStoreProvider options={{ client: open() }}>
        <ChatbookView />
      </AppStoreProvider>
    ), host)
    const button = (label: string) => Array.from(host.querySelectorAll('button'))
      .find((item) => (item.getAttribute('aria-label') ?? item.textContent?.trim()) === label)!
    try {
      await settle()
      const cleanUnload = new Event('beforeunload', { cancelable: true })
      window.dispatchEvent(cleanUnload)
      expect(cleanUnload.defaultPrevented).toBe(false)

      button('New notebook').click()
      const title = host.querySelector<HTMLTextAreaElement>('.new-notebook-editor textarea')!
      title.value = 'Still learning this'
      title.dispatchEvent(new Event('input', { bubbles: true }))
      const dirtyUnload = new Event('beforeunload', { cancelable: true })
      window.dispatchEvent(dirtyUnload)
      expect(dirtyUnload.defaultPrevented).toBe(true)

      button('Settings').click()
      button('New notebook').click()
      expect(host.querySelector<HTMLTextAreaElement>('.new-notebook-editor textarea')?.value).toBe('Still learning this')
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
      const notebooks = host.querySelector<HTMLButtonElement>('[aria-label="Notebooks"]')!
      const ai = host.querySelector<HTMLButtonElement>('[aria-label="AI"]')!

      expect(grid, host.textContent ?? '').not.toBeNull()

      expect(grid?.dataset.mobilePane).toBe('reader')
      expect(host.querySelector('.mobile-pane-nav')).toBeNull()
      expect(host.querySelector('.header-search')).toBeNull()

      notebooks.click()
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
      expect(grid?.dataset.mobilePane).toBe('files')

      ai.click()
      await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
      expect(grid?.dataset.mobilePane).toBe('details')
      host.querySelector<HTMLButtonElement>('[aria-label="Collapse the details pane"]')!.click()
      expect(host.querySelector('.chatbook')?.getAttribute('data-right')).toBe('closed')
      expect(grid?.dataset.mobilePane).toBe('reader')
      host.querySelector<HTMLButtonElement>('[aria-label="Tags"]')!.click()
      expect(host.querySelector('.chatbook')?.getAttribute('data-right')).toBe('open')
      expect(host.querySelector('#right-tab-info')?.getAttribute('aria-selected')).toBe('true')
    } finally {
      dispose()
      host.remove()
    }
  })
})
