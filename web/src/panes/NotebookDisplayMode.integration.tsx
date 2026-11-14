import { render } from 'solid-js/web'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { ReaderPane } from './ReaderPane'
import { FileTreeTab } from '../components/FileTreeTab'
import { parseNotebookDraft } from '../notes/notebookDraft'

let originalFetch: typeof fetch
beforeEach(() => {
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})
afterEach(() => { globalThis.fetch = originalFetch })

async function settle() { for (let i = 0; i < 6; i++) await new Promise((resolve) => setTimeout(resolve, 0)) }
function fixture(imported = false, selectedNote?: number, blankTitles = false) {
  const book: Notebook = { notebookId: notebookId('book'), type: 'DOCUMENT', title: 'Notebook', readOnly: imported,
    createdAt: '', updatedAt: '', tags: [], ...(imported ? { metaJSON: JSON.stringify({ source: { originalFilename: 'paper.pdf', format: 'pdf' } }) } : {}) }
  const notes: Note[] = [1, 2].map((i) => ({ noteId: noteId(`note-${i}`), notebookId: book.notebookId, noteNumber: i,
    title: blankTitles ? (i === 1 ? null : '  ') : `Note ${i}`, bodyMarkdown: `# Note ${i}\n\nOriginal ${i}`, readOnly: false, createdAt: '', updatedAt: '', tags: [] }))
  const updateNote = vi.fn(async (id: string, body: string) => { const note = notes.find((n) => n.noteId === id)!; note.bodyMarkdown = body; return { ...note } })
  const saveNotebookDraft = vi.fn(async (_id: string, body: string) => {
    const parsed = parseNotebookDraft(body)
    notes.splice(0, notes.length, ...parsed.notes.map((part, index) => ({
      ...notes[Math.min(index, notes.length - 1)]!, noteId: noteId(`note-${index + 1}`), noteNumber: index + 1,
      title: part.title, bodyMarkdown: part.bodyMarkdown,
    })))
    return book
  })
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [book], notebook: async () => book,
    notes: async () => notes, note: async (id: string) => notes.find((n) => n.noteId === id), noteFiles: async () => [],
    notebookComments: async () => [], notebookConversations: async () => [], agentModels: async () => ({ models: [], configuredModel: '' }),
    updateNote, saveNotebookDraft } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api,
    router: { currentHash: () => selectedNote ? `#/note/note-${selectedNote}` : '#/notebook/book', setHash: () => {}, addListener: () => {}, removeListener: () => {} },
  }}><FileTreeTab /><ReaderPane /></AppStoreProvider>, host)
  return { host, updateNote, saveNotebookDraft, close: () => { dispose(); host.remove() } }
}
test('Writing uses one Vim buffer and splits notes at <><>, while Preview keeps unsaved source', async () => {
  const view = fixture()
  try {
    await settle()
    const mode = view.host.querySelector('[aria-label="Notebook display mode"]')!
    const buttons = [...mode.querySelectorAll('button')]
    expect(view.host.querySelector('.reader-note-page')).toBeNull()
    expect(view.host.querySelectorAll('.reader-note-title')).toHaveLength(2)
    expect(view.host.querySelector('.study-note-button')).toBeNull()
    buttons.find((b) => b.textContent === 'Writing')!.click(); await settle()
    const editors = view.host.querySelectorAll<HTMLTextAreaElement>('.notebook-source')
    expect(editors).toHaveLength(1)
    const editor = editors[0]!
    expect(editor.value).toBe('# Note 1\n\nOriginal 1\n\n<><>\n\n# Note 2\n\nOriginal 2')
    expect(view.host.querySelectorAll('.vim-status')).toHaveLength(1)
    expect(view.host.querySelector('.notebook-writing-status .vim-status')).not.toBeNull()
    editor.focus(); editor.setSelectionRange(0, 0)
    const key = (key: string) => editor.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }))
    key('j'); expect(editor.selectionStart).toBeGreaterThan(0)
    key('k'); expect(editor.selectionStart).toBe(0)
    key('G'); expect(editor.selectionStart).toBeGreaterThan(editor.value.indexOf('# Note 2'))
    key('g'); key('g'); expect(editor.selectionStart).toBe(0)
    editor.value = '# Draft\n\nUnsaved\n\n<><>\n\nSecond\n\n<><>\n\nThird'
    editor.dispatchEvent(new Event('input', { bubbles: true }))
    buttons.find((b) => b.textContent === 'Preview')!.click(); await settle()
    expect(editor.hidden).toBe(true)
    expect(view.host.querySelectorAll('.notebook-source-preview .reader-note')).toHaveLength(3)
    expect(view.host.querySelector('.notebook-source-preview')?.textContent).toContain('Unsaved')
    expect(view.host.querySelectorAll('.notebook-source-preview .reader-note-title')).toHaveLength(0)
    expect(view.host.querySelector('.notebook-source-preview .study-note-button')).toBeNull()
    expect(view.saveNotebookDraft).not.toHaveBeenCalled()
    buttons.find((b) => b.textContent === 'Writing')!.click(); await settle()
    expect(view.host.querySelector('.notebook-source')).toBe(editor)
    expect(editor.hidden).toBe(false); expect(editor.value).toContain('Third')
    view.host.querySelector('.notebook-writing-form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); await settle()
    expect(view.saveNotebookDraft).toHaveBeenCalledWith('book', editor.value, 'Notebook')
    expect(view.updateNote).not.toHaveBeenCalled()
    expect(view.host.querySelectorAll('.notebook-source')).toHaveLength(1)
    expect(view.host.querySelector('[role="status"]')?.textContent).toBe('Saved')
  } finally { view.close() }
})
test('empty or missing metadata titles never create fallback labels in either Preview', async () => {
  const view = fixture(false, undefined, true)
  try {
    await settle()
    expect(view.host.querySelector('.reader-note-title')).toBeNull()
    const buttons = [...view.host.querySelectorAll<HTMLButtonElement>('[aria-label="Notebook display mode"] button')]
    buttons.find((button) => button.textContent === 'Writing')!.click(); await settle()
    buttons.find((button) => button.textContent === 'Preview')!.click(); await settle()
    expect(view.host.querySelector('.notebook-source-preview')).not.toBeNull()
    expect(view.host.querySelector('.reader-note-title')).toBeNull()
    expect(view.host.querySelectorAll('.notebook-source-preview h1')).toHaveLength(2)
  } finally { view.close() }
})
test('the workspace writing event starts inserting at the selected note in one notebook buffer', async () => {
  const view = fixture(false, 2)
  try {
    await settle()
    expect(view.host.querySelector('.notebook-source')).toBeNull()
    window.dispatchEvent(new Event('kaiba-write-notebook'))
    await settle()
    const editor = view.host.querySelector<HTMLTextAreaElement>('.notebook-source')!
    expect(editor).not.toBeNull()
    expect(document.activeElement).toBe(editor)
    expect(view.host.querySelector('.vim-status-mode')?.textContent).toBe('INSERT')
    expect(editor.selectionStart).toBe(editor.value.indexOf('# Note 2'))
    expect(view.host.querySelectorAll('.vim-status')).toHaveLength(1)
  } finally { view.close() }
})
test('imported notebook shows a file instead of a lock and remains read-only', async () => {
  const view = fixture(true)
  try {
    await settle()
    expect(view.host.querySelector('[aria-label="Imported file: paper.pdf"]')).not.toBeNull()
    expect(view.host.querySelector('[aria-label="Read-only notebook"]')).toBeNull()
    const write = [...view.host.querySelectorAll<HTMLButtonElement>('[aria-label="Notebook display mode"] button')].find((button) => button.textContent === 'Writing')!
    expect(write.disabled).toBe(true)
  } finally { view.close() }
})

test('an unsaved middle split keeps following metadata on its original note', async () => {
  const view = fixture()
  try {
    await settle()
    const buttons = [...view.host.querySelectorAll<HTMLButtonElement>('[aria-label="Notebook display mode"] button')]
    buttons.find((button) => button.textContent === 'Writing')!.click(); await settle()
    const editor = view.host.querySelector<HTMLTextAreaElement>('.notebook-source')!
    editor.value = '# Note 1\n\nOriginal 1\n\n<><>\n\nNew inserted section\n\n<><>\n\n# Note 2\n\nOriginal 2'
    editor.dispatchEvent(new Event('input', { bubbles: true }))
    buttons.find((button) => button.textContent === 'Preview')!.click(); await settle()
    const sections = view.host.querySelectorAll<HTMLElement>('.notebook-source-preview .reader-note')
    expect(sections).toHaveLength(3)
    expect(sections[0]!.dataset.noteId).toBe('note-1')
    expect(sections[1]!.dataset.noteId).toBeUndefined()
    expect(sections[1]!.querySelector('.reader-note-title')).toBeNull()
    expect(sections[2]!.dataset.noteId).toBe('note-2')
    expect(sections[2]!.querySelector('.reader-note-title')?.textContent).toBe('Note 2')
  } finally { view.close() }
})
