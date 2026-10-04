import { noteId as asNoteId, notebookId as asNotebookId } from '../notes/ids'
import type { NoteId, NotebookId } from '../notes/ids'
import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import type { EngineNoteHit, Note } from '../notes/types'
import type { AppStore } from '../state/appStore'
import { RelatedNotesSection } from './RelatedNotesSection'

const sourceId = asNoteId('source')
const notebook = asNotebookId('book')
const hits: EngineNoteHit[] = [
  { note: makeNote('related-1', 'Related one'), snippet: 'first snippet', score: 2 },
  { note: makeNote('related-2', 'Related two'), snippet: 'second snippet', score: 1 },
]

function makeNote(id: string, title: string): Note {
  return {
    noteId: asNoteId(id), notebookId: notebook, noteNumber: 1, title,
    bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '',
  }
}

function testStore(
  enabled: boolean,
  relatedNotes: (noteId: NoteId, limit?: number) => Promise<EngineNoteHit[]> = vi.fn(async () => hits),
  openNote: (noteId: NoteId, notebookId?: NotebookId) => void = vi.fn(),
): AppStore {
  return {
    state: {
      searchEngineEnabled: enabled,
      noteId: sourceId,
      notebookId: notebook,
      notebookRevisions: {},
    },
    client: { relatedNotes } as unknown as NoteGraphQLClient,
    openNote,
  } as unknown as AppStore
}

async function settle(): Promise<void> {
  await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
}

describe('RelatedNotesSection', () => {
  test('stays hidden and does not fetch when the capability is disabled', async () => {
    const relatedNotes = vi.fn(async () => hits)
    const host = document.createElement('div')
    const dispose = render(() => <RelatedNotesSection app={testStore(false, relatedNotes)} />, host)
    try {
      await settle()
      expect(host.querySelector('[aria-label="Related notes"]')).toBeNull()
      expect(relatedNotes).not.toHaveBeenCalled()
    } finally { dispose(); host.remove() }
  })

  test('renders related titles and opens the selected note', async () => {
    const openNote = vi.fn()
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <RelatedNotesSection app={testStore(true, async () => hits, openNote)} />, host)
    try {
      await settle()
      const buttons = host.querySelectorAll<HTMLButtonElement>('[aria-label="Related notes"] button')
      expect(buttons).toHaveLength(2)
      expect(buttons[0]?.textContent).toContain('Related one')
      expect(buttons[1]?.textContent).toContain('Related two')
      buttons[0]?.click()
      expect(openNote).toHaveBeenCalledWith(hits[0]?.note.noteId, hits[0]?.note.notebookId)
    } finally { dispose(); host.remove() }
  })

  test('reports unavailable related notes', async () => {
    const host = document.createElement('div')
    const dispose = render(() => <RelatedNotesSection app={testStore(true, async () => { throw new Error('offline') })} />, host)
    try {
      await settle()
      expect(host.textContent).toContain('Related notes unavailable')
    } finally { dispose(); host.remove() }
  })

  test('reports when no related notes are found', async () => {
    const host = document.createElement('div')
    const dispose = render(() => <RelatedNotesSection app={testStore(true, async () => [])} />, host)
    try {
      await settle()
      expect(host.textContent).toContain('No related notes')
    } finally { dispose(); host.remove() }
  })
})
