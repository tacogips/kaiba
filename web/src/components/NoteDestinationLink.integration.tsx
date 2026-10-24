import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import type { Note } from '../notes/types'
import type { AppStore } from '../state/appStore'
import { NoteDestinationLink } from './NoteDestinationLink'

const destination: Note = { noteId: noteId('target'), notebookId: notebookId('target-book'), noteNumber: 7,
  title: 'Destination heading', bodyMarkdown: 'Preview body', readOnly: false, createdAt: '', updatedAt: '', metaJSON: null }
function mount(note = destination, resolveNote = vi.fn(async () => note)) {
  const openNote = vi.fn()
  const documentPageText = vi.fn(async () => ({ text: 'PDF searchable text\nSecond line' }))
  const app = { state: { notebooks: [{ notebookId: note.notebookId, title: 'Destination document.pdf' }] },
    client: { note: resolveNote, documentPageText }, openNote } as unknown as AppStore
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <NoteDestinationLink app={app} note={note} relationship="Outgoing · source citation · Added manually" />, host)
  return { host, openNote, documentPageText, close: () => { dispose(); host.remove() } }
}

describe('Connection destination preview', () => {
  test('shows destination document and position; hover previews without navigation and popup opens destination', async () => {
    const view = mount()
    try {
      expect(view.host.textContent).toContain('Destination document.pdf · Note 7')
      expect(view.host.textContent).toContain('Outgoing · source citation')
      view.host.querySelector('.note-destination')!.dispatchEvent(new Event('pointerenter'))
      await vi.waitFor(() => expect(document.querySelector('[role="dialog"]')?.textContent).toContain('Preview body'))
      expect(view.openNote).not.toHaveBeenCalled()
      const popup = document.querySelector('[role="dialog"]')!
      ;[...popup.querySelectorAll('button')].find((button) => button.textContent === 'Open note')!.click()
      expect(view.openNote).toHaveBeenCalledWith(destination.noteId, destination.notebookId)
      expect(document.querySelector('[role="dialog"]')).toBeNull()
    } finally { view.close() }
  })

  test('keyboard focus and touch preview work, Escape closes without navigating', async () => {
    const view = mount()
    try {
      view.host.querySelector<HTMLButtonElement>('.note-destination-open')!.focus()
      await vi.waitFor(() => expect(document.querySelector('[role="dialog"]')?.textContent).toContain('Preview body'))
      document.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      expect(document.querySelector('[role="dialog"]')).toBeNull()
      view.host.querySelector<HTMLButtonElement>('[aria-label="Preview Destination heading"]')!.click()
      await vi.waitFor(() => expect(document.querySelector('[role="dialog"]')).not.toBeNull())
      expect(view.openNote).not.toHaveBeenCalled()
    } finally { view.close() }
  })

  test('PDF previews use extracted text rather than the empty note body', async () => {
    const note = { ...destination, bodyMarkdown: '', metaJSON: JSON.stringify({ documentPage: {
      pageNumber: 7, ocrState: 'complete', originFileId: 'file-original', originMediaType: 'application/pdf', analysis: {},
    } }) }
    const view = mount(note)
    try {
      view.host.querySelector<HTMLButtonElement>('.note-preview-trigger')!.click()
      await vi.waitFor(() => expect(document.querySelector('[role="dialog"] pre')?.textContent).toContain('PDF searchable text\nSecond line'))
      expect(view.documentPageText).toHaveBeenCalledWith(note.noteId)
      expect(view.host.textContent).toContain('Destination document.pdf · Page 7')
      expect(document.querySelector('[role="dialog"]')?.textContent).toContain('Original page')
      expect(view.openNote).not.toHaveBeenCalled()
    } finally { view.close() }
  })

  test('closing a pending request prevents stale preview content', async () => {
    let resolve!: (note: Note) => void
    const pending = vi.fn(() => new Promise<Note>((done) => { resolve = done }))
    const view = mount({ ...destination, metaJSON: undefined }, pending)
    try {
      view.host.querySelector<HTMLButtonElement>('.note-preview-trigger')!.click()
      document.querySelector<HTMLButtonElement>('[aria-label="Close link preview"]')!.click()
      resolve(destination)
      await Promise.resolve()
      expect(document.querySelector('[role="dialog"]')).toBeNull()
      expect(view.openNote).not.toHaveBeenCalled()
    } finally { view.close() }
  })
})
