import { expect, test } from 'bun:test'
import { aiNoteContext } from './aiNoteContext'
import type { NoteGraphQLClient } from './client'
import type { Note, Notebook } from './types'
import { notebookId, noteId } from './ids'
import { testDocumentPage } from './documentPageFixtures'

const book: Notebook = { notebookId: notebookId('book'), title: 'Reference book', type: 'DOCUMENT', readOnly: false,
  noteCount: 1000, tags: [], createdAt: '', updatedAt: '' }
const notes: Note[] = Array.from({ length: 1000 }, (_, index) => ({ noteId: noteId(`n${index + 1}`), notebookId: book.notebookId,
  noteNumber: index + 1, title: `Title ${index + 1}`, bodyMarkdown: `Body ${index + 1}`, readOnly: false, tags: [], createdAt: '', updatedAt: '' }))
const decode = (attachments: Awaited<ReturnType<typeof aiNoteContext>>) => new TextDecoder().decode(Uint8Array.from(atob(attachments[0]!.contentBase64), (character) => character.charCodeAt(0)))
test('explicit ranges fetch the selected notes across batches and exclude others', async () => {
  const offsets: number[] = []
  const client = { notes: async (_id: string, offset: number) => { offsets.push(offset); return notes.slice(offset, offset + 200) } } as unknown as NoteGraphQLClient
  const result = await aiNoteContext(client, book, notes[0], { mode: 'range', start: '201', end: '401' })
  const text = decode(result)
  expect(offsets).toEqual([200, 400]); expect(text).toContain('Body 201'); expect(text).toContain('Body 401')
  expect(text).not.toContain('Body 200'); expect(text).not.toContain('Body 402')
  await expect(aiNoteContext(client, book, undefined, { mode: 'range', start: '9', end: '3' })).rejects.toThrow('valid note')
})
test('current PDF uses searchable page text, and a writing buffer supplies current unsaved note context', async () => {
  const page = { ...notes[2]!, documentPage: testDocumentPage({ pageNumber: 3 }) }
  const client = { documentPageText: async () => ({ text: '検索用 OCR content' }) } as unknown as NoteGraphQLClient
  expect(decode(await aiNoteContext(client, book, page, { mode: 'current', start: '', end: '' }))).toContain('検索用 OCR content')
  const draft = { source: 'First draft\n\n<><>\n\nUnsaved second', noteNumber: 2 }
  const text = decode(await aiNoteContext(client, book, notes[0], { mode: 'current', start: '', end: '' }, draft))
  expect(text).toContain('Unsaved second'); expect(text).not.toContain('First draft')
})
test('current context rejects a stale selection from another notebook before reading its content', async () => {
  let read = false
  const client = { documentPageText: async () => { read = true; return { text: 'Private old notebook content' } } } as unknown as NoteGraphQLClient
  const stale = { ...notes[0]!, notebookId: notebookId('previous-book'), documentPage: testDocumentPage({ pageNumber: 1 }) }
  await expect(aiNoteContext(client, book, stale, { mode: 'current', start: '', end: '' })).rejects.toThrow('Select a note in this notebook')
  expect(read).toBe(false)
})
test('a draft range can include newly split notes that have not reached the saved note count yet', async () => {
  const draft = { source: 'Saved first\n\n<><>\n\nNew second\n\n<><>\n\nNew third', noteNumber: 3 }
  const text = decode(await aiNoteContext({} as NoteGraphQLClient, { ...book, noteCount: 1 }, notes[0], { mode: 'range', start: '2', end: '3' }, draft))
  expect(text).toContain('New second'); expect(text).toContain('New third'); expect(text).not.toContain('Saved first')
})
