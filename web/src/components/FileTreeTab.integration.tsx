import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { FileTreeTab } from './FileTreeTab'

test('1000 notes load near the tree end without replacing existing rows or losing scroll position', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const originalObserver = globalThis.IntersectionObserver
  let intersect: IntersectionObserverCallback | undefined
  let observed: Element | undefined
  globalThis.IntersectionObserver = class {
    constructor(callback: IntersectionObserverCallback) { intersect = callback }
    observe(element: Element) { observed = element }
    disconnect() {}
  } as unknown as typeof IntersectionObserver
  const book: Notebook = { notebookId: notebookId('large'), title: 'Large notebook', type: 'DOCUMENT', readOnly: false,
    createdAt: '', updatedAt: '', tags: [], noteCount: 1000 }
  const notes: Note[] = Array.from({ length: 1000 }, (_, index) => ({ noteId: noteId(`page-${index + 1}`),
    notebookId: book.notebookId, noteNumber: index + 1, title: `Topic ${index + 1}`, bodyMarkdown: '',
    readOnly: false, tags: [], createdAt: '', updatedAt: '' }))
  let held = false
  let release: (() => void) | undefined
  const readNotes = vi.fn(async (_id: string, offset = 0) => {
    if (offset === 200 && !held) { held = true; await new Promise<void>((resolve) => { release = resolve }) }
    return notes.slice(offset, offset + 200).map((note) => ({ ...note }))
  })
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [{ ...book }], notes: readNotes,
  } as unknown as NoteGraphQLClient
  let app!: AppStore
  const Tree = () => { app = useApp(); return <div class="pane-body"><FileTreeTab /></div> }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api,
    router: { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} },
  }}><Tree /></AppStoreProvider>, host)
  const settle = async () => { for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0)) }
  const rows = () => host.querySelectorAll('[aria-level="2"]')
  try {
    await settle()
    host.querySelector<HTMLButtonElement>('[aria-label="Expand Large notebook"]')!.click(); await settle()
    expect(rows()).toHaveLength(200); expect(readNotes).toHaveBeenCalledTimes(1)
    const first = rows()[0]!
    const scroller = host.querySelector<HTMLElement>('.pane-body')!; scroller.scrollTop = 4300
    intersect!([{ isIntersecting: true, target: observed! } as IntersectionObserverEntry], {} as IntersectionObserver)
    const pending = app.loadMoreNotes(book.notebookId)
    expect(readNotes).toHaveBeenCalledTimes(2)
    expect(rows()).toHaveLength(200); expect(rows()[0]).toBe(first)
    release!(); await pending; await settle()
    expect(rows()).toHaveLength(400); expect(rows()[0]).toBe(first); expect(scroller.scrollTop).toBe(4300)
    for (let count = 600; count <= 1000; count += 200) {
      intersect!([{ isIntersecting: true, target: observed! } as IntersectionObserverEntry], {} as IntersectionObserver)
      await settle(); expect(rows()).toHaveLength(count); expect(rows()[0]).toBe(first)
    }
    expect(app.canLoadMoreNotes(book.notebookId)).toBe(false)
    await app.loadMoreNotes(book.notebookId); expect(readNotes).toHaveBeenCalledTimes(5)
    await app.refreshCatalog(); await app.loadNotes(book.notebookId); await settle()
    expect(rows()).toHaveLength(1000); expect(rows()[0]).toBe(first); expect(scroller.scrollTop).toBe(4300)
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch; globalThis.IntersectionObserver = originalObserver }
})

async function mountAdditionalTree(read?: (offset: number, notes: Note[]) => Promise<Note[]>, count = 1000) {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const originalObserver = globalThis.IntersectionObserver
  let intersect: IntersectionObserverCallback | undefined
  let observed: Element | undefined
  globalThis.IntersectionObserver = class {
    constructor(callback: IntersectionObserverCallback) { intersect = callback }
    observe(element: Element) { observed = element }
    disconnect() {}
  } as unknown as typeof IntersectionObserver
  const book: Notebook = { notebookId: notebookId('large'), title: 'Large notebook', type: 'DOCUMENT', readOnly: false,
    createdAt: '', updatedAt: '', tags: [], noteCount: count }
  const notes: Note[] = Array.from({ length: count }, (_, index) => ({ noteId: noteId(`page-${index + 1}`),
    notebookId: book.notebookId, noteNumber: index + 1, title: `Topic ${index + 1}`, bodyMarkdown: '',
    readOnly: false, tags: [], createdAt: '', updatedAt: '' }))
  const readNotes = vi.fn(async (_id: string, offset = 0) => read ? read(offset, notes) : notes.slice(offset, offset + 200).map((note) => ({ ...note })))
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [{ ...book }], notes: readNotes,
  } as unknown as NoteGraphQLClient
  let app!: AppStore
  const Tree = () => { app = useApp(); return <div class="pane-body"><FileTreeTab /></div> }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api,
    router: { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} },
  }}><Tree /></AppStoreProvider>, host)
  const settle = async () => { for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0)) }
  await settle()
  host.querySelector<HTMLButtonElement>('[aria-label="Expand Large notebook"]')!.click()
  return {
    host, book, app, readNotes, settle,
    rows: () => host.querySelectorAll('[aria-level="2"]'),
    nearEnd: () => intersect!([{ isIntersecting: true, target: observed! } as IntersectionObserverEntry], {} as IntersectionObserver),
    close: () => { dispose(); host.remove(); globalThis.fetch = originalFetch; globalThis.IntersectionObserver = originalObserver },
  }
}

test('cached notes loaded by the reader still mount in 200-row tree batches', async () => {
  const view = await mountAdditionalTree()
  try {
    await view.settle()
    for (let page = 1; page < 5; page++) await view.app.loadMoreNotes(view.book.notebookId)
    expect(view.app.state.notesByNotebook[view.book.notebookId]).toHaveLength(1000)
    expect(view.rows()).toHaveLength(200)
    const first = view.rows()[0]
    for (let count = 400; count <= 1000; count += 200) {
      view.nearEnd(); await view.settle()
      expect(view.rows()).toHaveLength(count); expect(view.rows()[0]).toBe(first)
    }
    expect(view.readNotes).toHaveBeenCalledTimes(5)
    expect(view.host.textContent).not.toContain('Load more notes')
  } finally { view.close() }
})

test('initial pending or failed requests never present the notebook as empty and can retry', async () => {
  let rejectInitial!: (error: Error) => void
  let first = true
  const view = await mountAdditionalTree(async () => {
    if (first) { first = false; return new Promise<Note[]>((_resolve, reject) => { rejectInitial = reject }) }
    return []
  }, 0)
  try {
    expect(view.host.textContent).toContain('Loading notes…')
    expect(view.host.textContent).not.toContain('No notes.')
    rejectInitial(new Error('Offline')); await view.settle()
    expect(view.host.textContent).toContain('Could not load notes.')
    expect(view.host.textContent).not.toContain('No notes.')
    const retry = [...view.host.querySelectorAll<HTMLButtonElement>('button')].find((button) => button.textContent === 'Retry loading notes')!
    retry.click(); await view.settle()
    expect(view.host.textContent).toContain('No notes.')
    expect(view.host.textContent).not.toContain('Loading notes…')
    expect(view.readNotes).toHaveBeenCalledTimes(2)
  } finally { view.close() }
})

test('a failed next batch keeps existing rows and the same retry position', async () => {
  let fail = true
  const view = await mountAdditionalTree(async (offset, notes) => {
    if (offset === 200 && fail) { fail = false; throw new Error('Offline') }
    return notes.slice(offset, offset + 200).map((note) => ({ ...note }))
  })
  try {
    await view.settle()
    const first = view.rows()[0]
    view.nearEnd(); await view.settle()
    expect(view.rows()).toHaveLength(200); expect(view.rows()[0]).toBe(first)
    const more = [...view.host.querySelectorAll<HTMLButtonElement>('button')].find((button) => button.textContent === 'Load more notes')!
    more.click(); await view.settle()
    expect(view.rows()).toHaveLength(400); expect(view.rows()[0]).toBe(first)
    expect(view.readNotes.mock.calls.map((call) => call[1])).toEqual([0, 200, 200])
  } finally { view.close() }
})
