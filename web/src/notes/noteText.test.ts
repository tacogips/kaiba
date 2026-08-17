import { noteId as asNoteId, notebookId as asNotebookId } from './ids'
import { describe, expect, test } from 'bun:test'
import { derivedNoteTitle, noteDisplayTitle, noteExportFilename } from './noteText'
import type { Note } from './types'

const note = (overrides: Partial<Note> = {}): Note => ({
  noteId: asNoteId('note-1'),
  notebookId: asNotebookId('book-1'),
  noteNumber: 7,
  title: 'Title',
  bodyMarkdown: 'body',
  readOnly: false,
  createdAt: '',
  updatedAt: '',
  ...overrides,
})

describe('composed title preview', () => {
  test('prefers the first heading, then the first line, then the default', () => {
    expect(derivedNoteTitle('intro\n\n# Real title\nmore')).toBe('Real title')
    expect(derivedNoteTitle('plain first line\nsecond')).toBe('plain first line')
    expect(derivedNoteTitle('   \n\n')).toBe('Untitled')
    expect(derivedNoteTitle('## Closed ##')).toBe('Closed')
  })

  test('caps a very long title', () => {
    expect(derivedNoteTitle('y'.repeat(200))).toBe(`${'y'.repeat(120)}…`)
  })
})

describe('display title', () => {
  test('falls back to the note number when the title is missing or blank', () => {
    expect(noteDisplayTitle(note())).toBe('Title')
    expect(noteDisplayTitle(note({ title: null }))).toBe('Note 7')
    expect(noteDisplayTitle(note({ title: '   ' }))).toBe('Note 7')
  })
})

describe('export filename', () => {
  test('slugs the title and caps the segment count', () => {
    expect(noteExportFilename('Design Decisions: W1')).toBe('design-decisions-w1.md')
    expect(noteExportFilename('Chatbook Orchestration: Add-ons & Fanout Design Review Notes Extra Tail'))
      .toBe('chatbook-orchestration-add-ons-fanout-design-review-notes.md')
    expect(noteExportFilename('   ')).toBe('note.md')
  })

  test('falls back when the title has no latin characters', () => {
    expect(noteExportFilename('日本語タイトル')).toBe('note.md')
  })
})
