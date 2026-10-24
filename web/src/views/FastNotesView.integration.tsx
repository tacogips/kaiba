import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import type { RouterEnvironment } from '../router'
import { ChatbookView } from './ChatbookView'

vi.mock('../notes/events', () => ({ subscribeNoteEvents: () => () => undefined }))

function mount(failFirst = false) {
  let hash = '#/fast'
  const listeners = new Set<() => void>()
  const router: RouterEnvironment = { currentHash: () => hash,
    setHash: (next) => { hash = next; for (const listener of listeners) listener() },
    addListener: (callback) => { listeners.add(callback) }, removeListener: (callback) => { listeners.delete(callback) } }
  const book: Notebook = { notebookId: notebookId('quick'), title: 'Quick Memos', type: 'DOCUMENT', readOnly: false, tags: [], createdAt: '', updatedAt: '' }
  const rows: Note[] = Array.from({ length: 55 }, (_, index) => ({ noteId: noteId(`note-${index}`), notebookId: book.notebookId, noteNumber: index + 1,
    title: index === 54 ? 'Searchable oldest' : `Thought ${index}`, bodyMarkdown: `# Thought ${index}\n\nBody ${index}`, tags: [], readOnly: false,
    createdAt: new Date(Date.UTC(2025, 0, 55 - index)).toISOString(), updatedAt: '2026-10-24T00:00:00Z' }))
  const fastNotes = vi.fn(async (query = '', offset = 0, limit = 50) => rows.filter((note) => `${note.title} ${note.bodyMarkdown}`.toLowerCase().includes(query.toLowerCase())).slice(offset, offset + limit))
  if (failFirst) fastNotes.mockRejectedValueOnce(new Error('Feed unavailable'))
  const captureNote = vi.fn(async (body: string) => {
    const note = { ...rows[0]!, noteId: noteId('captured'), bodyMarkdown: body, title: 'Captured thought', createdAt: '2026-10-24T00:00:00Z' }
    rows.unshift(note)
    return { noteId: note.noteId, notebookId: book.notebookId, noteNumber: 56 }
  })
  const notes = vi.fn(async () => rows)
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined, searchEngineCapability: async () => false,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [book], notebook: async () => book, notes,
    note: async (id: string) => rows.find((row) => row.noteId === id), agentModels: async () => ({ models: [], configuredModel: '' }),
    fastNotes, captureNote,
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router, paneStorage: { getItem: () => null, setItem: () => {} } }}><ChatbookView /></AppStoreProvider>, host)
  return { host, fastNotes, captureNote, notes, hash: () => hash, close: () => { dispose(); host.remove() } }
}
const wait = (check: () => void) => vi.waitFor(check, { timeout: 5000 })

test('Fast Note pages, searches, and preserves cards/query when returning from one selected note', async () => {
  const view = mount()
  try {
    await wait(() => expect(view.host.querySelectorAll('.fast-note-card')).toHaveLength(50))
    expect(view.host.querySelector('.pane-left')).toBeNull()
    expect(view.host.querySelector('.pane-right')).toBeNull()
    const load = Array.from(view.host.querySelectorAll('button')).find((button) => button.textContent === 'Load more notes')!
    load.click()
    await wait(() => expect(view.host.querySelectorAll('.fast-note-card')).toHaveLength(55))
    expect(view.fastNotes).toHaveBeenCalledWith('', 50, 50)
    view.host.querySelector<HTMLButtonElement>('[aria-label="Card view"]')!.click()
    expect(view.host.querySelector('.fast-feed-cards')).not.toBeNull()
    const search = view.host.querySelector<HTMLInputElement>('[aria-label="Search fast notes"]')!
    search.value = 'Searchable'; search.dispatchEvent(new Event('input', { bubbles: true }))
    await wait(() => expect(view.host.querySelectorAll('.fast-note-card')).toHaveLength(1))
    view.host.querySelector<HTMLButtonElement>('.fast-note-card')!.click()
    await wait(() => expect(view.host.querySelector('.fast-note-body')?.textContent).toContain('Body 54'))
    expect(view.host.querySelector('.pane-left')).toBeNull()
    expect(view.host.querySelector('.pane-right')).not.toBeNull()
    expect(view.host.querySelectorAll('.fast-note-body article')).toHaveLength(0)
    expect(view.notes).not.toHaveBeenCalled()
    view.host.querySelector<HTMLButtonElement>('[aria-label="Back to notes"]')!.click()
    await wait(() => expect(view.host.querySelector('.fast-feed-cards')).not.toBeNull())
    expect(view.host.querySelector<HTMLInputElement>('[aria-label="Search fast notes"]')?.value).toBe('Searchable')
    expect(view.host.querySelectorAll('.fast-note-card')).toHaveLength(1)
    expect(view.host.querySelector('.pane-right')).toBeNull()
    expect(view.hash()).toContain('layout=cards')
    view.host.querySelector<HTMLButtonElement>('[aria-label="Notebooks"]')!.click()
    await wait(() => expect(view.host.querySelector('.pane-left')).not.toBeNull())
  } finally { view.close() }
})

test('quick capture creates one note and opens it with details, then returns to the feed', async () => {
  const view = mount()
  try {
    await wait(() => expect(view.host.querySelector('.fast-note-card')).not.toBeNull())
    const input = view.host.querySelector<HTMLTextAreaElement>('[aria-label="Write a quick note"]')!
    input.value = '# Captured thought\n\n**Markdown remains intact**\n----\nStill the same quick note'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    view.host.querySelector<HTMLButtonElement>('[aria-label="Save quick note"]')!.click()
    await wait(() => expect(view.host.querySelector('.fast-note-body strong')?.textContent).toBe('Markdown remains intact'))
    expect(view.captureNote).toHaveBeenCalledTimes(1)
    expect(view.host.querySelector('.pane-right')).not.toBeNull()
    view.host.querySelector<HTMLButtonElement>('[aria-label="Back to notes"]')!.click()
    await wait(() => expect(view.host.querySelector('.fast-note-card h2')?.textContent).toBe('Captured thought'))
  } finally { view.close() }
})

test('a feed failure displays a retry action without crashing the workspace', async () => {
  const view = mount(true)
  try {
    await wait(() => expect(view.host.querySelector('[role="alert"]')?.textContent).toContain('Feed unavailable'))
    Array.from(view.host.querySelectorAll('button')).find((button) => button.textContent === 'Retry')!.click()
    await wait(() => expect(view.host.querySelectorAll('.fast-note-card')).toHaveLength(50))
  } finally { view.close() }
})
