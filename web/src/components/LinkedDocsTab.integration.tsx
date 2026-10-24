import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { LinkedDocsTab } from './LinkedDocsTab'
import type { Note, NoteLink } from '../notes/types'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))
const current = noteId('current')
const source = noteId('source')
const note = (id: string): Note => ({ noteId: noteId(id), notebookId: notebookId('other'), noteNumber: 4, title: `Source ${id}`,
  bodyMarkdown: '**Cited words**', readOnly: false, createdAt: '', updatedAt: '', metaJSON: null })
const edge = (from: string, to: string, kind = 'reference', provenance = 'human'): NoteLink => ({ fromNoteId: noteId(from), toNoteId: noteId(to), linkKind: kind, provenance, createdAt: '2026-10-24T00:00:00Z' })

function mount(links: NoteLink[], selected: string | null = current) {
  const openNote = vi.fn()
  const readNote = vi.fn(async (id: string) => note(id))
  const readLinks = vi.fn(async () => links)
  fixture.app = { state: { noteId: selected ?? undefined, notebookId: notebookId('current'), notebookRevisions: {}, catalogRevision: 1,
    notebooks: [{ notebookId: notebookId('other'), title: 'Referring notebook' }] },
    client: { note: readNote, noteLinks: readLinks }, openNote }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <LinkedDocsTab />, host)
  return { host, readNote, readLinks, openNote, close: () => { dispose(); host.remove() } }
}

describe('Backlinks', () => {
  test('shows incoming sources once with link meaning, preview, and jump; excludes outgoing and self links', async () => {
    const view = mount([edge(source, current), edge(source, current, 'source-citation', 'ai'), edge(current, 'outgoing'), edge(current, current)])
    try {
      await vi.waitFor(() => expect(view.host.textContent).toContain('Links to this note · reference · Added manually'))
      expect(view.host.textContent).toContain('source citation · Added by ai')
      expect(view.host.textContent).toContain('1 referring note')
      expect(view.host.querySelectorAll('.note-destination')).toHaveLength(1)
      expect(view.readNote).not.toHaveBeenCalledWith('outgoing')
      expect(view.host.textContent).toContain('Referring notebook · Note 4')
      view.host.querySelector<HTMLButtonElement>('[aria-label="Preview Source source"]')!.click()
      await vi.waitFor(() => expect(document.querySelector('[role="dialog"] strong')?.textContent).toBe('Source source'))
      await vi.waitFor(() => expect(document.querySelector('.note-link-preview-content strong')?.textContent).toBe('Cited words'))
      expect(view.openNote).not.toHaveBeenCalled()
      view.host.querySelector<HTMLButtonElement>('.note-destination-open')!.click()
      expect(view.openNote).toHaveBeenCalledWith(source, notebookId('other'))
    } finally { view.close() }
  })

  test('outgoing links alone produce an empty backlinks list', async () => {
    const view = mount([edge(current, 'outgoing')])
    try {
      await vi.waitFor(() => expect(view.host.textContent).toContain('No notes link to this note yet.'))
      expect(view.readNote).not.toHaveBeenCalled()
    } finally { view.close() }
  })

  test('loads all incoming sources in pages rather than truncating to graph-neighbor limits', async () => {
    const view = mount(Array.from({ length: 55 }, (_, index) => edge(`source-${index}`, current)))
    try {
      await vi.waitFor(() => expect(view.host.querySelectorAll('.note-destination')).toHaveLength(50))
      expect(view.host.textContent).toContain('55 referring notes')
      Array.from(view.host.querySelectorAll('button')).find((button) => button.textContent === 'Load more backlinks')!.click()
      await vi.waitFor(() => expect(view.host.querySelectorAll('.note-destination')).toHaveLength(55))
    } finally { view.close() }
  })

  test('requires a selected note instead of showing mixed notebook-wide links', () => {
    const view = mount([], null)
    try { expect(view.host.textContent).toContain('Select a note or page'); expect(view.readLinks).not.toHaveBeenCalled() }
    finally { view.close() }
  })
})
