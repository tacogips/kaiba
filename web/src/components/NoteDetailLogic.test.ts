import { describe, expect, test } from 'bun:test'
import { APIError } from '../api'
import {
  adjacentNoteId,
  allowedLinkKind,
  appendReaderPage,
  attachmentView,
  counterpartNoteId,
  derivedNoteTitle,
  earlierPageRequest,
  laterPageOffset,
  linkLabel,
  linkStableId,
  needsEarlierPage,
  needsLaterPage,
  noteTagNames,
  openLinkProposals,
  prependReaderPage,
  readerPositionLabel,
  replaceReaderNote,
  rewriteResultIsFresh,
  selectedText,
  selectionQuestionComment,
  applyRewrite,
  workspaceErrorMessage,
  type ReaderWindow,
} from './NoteDetailLogic'
import type { Note } from '../notes/types'

const note = (index: number): Note => ({
  noteId: `note-${index}`,
  notebookId: 'book-1',
  noteNumber: index,
  title: `Note ${index}`,
  bodyMarkdown: `body ${index}`,
  readOnly: false,
  createdAt: '',
  updatedAt: '',
})

const window = (indices: number[], overrides: Partial<ReaderWindow> = {}): ReaderWindow => ({
  notes: indices.map(note),
  startOffset: 0,
  hasEarlier: false,
  hasMore: false,
  ...overrides,
})

describe('link presentation', () => {
  const link = { linkId: '', fromNoteId: 'note-1', toNoteId: 'note-2', linkKind: 'related', provenance: null, createdAt: '' }

  test('keys links by both endpoints and the kind', () => {
    expect(linkStableId(link)).toBe('note-1-note-2-related')
  })

  test('resolves the counterpart from either direction', () => {
    expect(counterpartNoteId(link, 'note-1')).toBe('note-2')
    expect(counterpartNoteId(link, 'note-2')).toBe('note-1')
  })

  test('labels a link with the linked note title, falling back to the id', () => {
    expect(linkLabel(link, 'note-1', { 'note-2': note(2) })).toBe('related: Note 2')
    expect(linkLabel(link, 'note-1', {})).toBe('related: note-2')
  })

  test('normalizes unknown link kinds to related', () => {
    expect(allowedLinkKind(' source-citation ')).toBe('source-citation')
    expect(allowedLinkKind('mentions')).toBe('related')
  })

  test('hides proposals that are already linked or self-referential', () => {
    const proposals = [
      { targetNote: note(2), linkKind: 'related', reason: 'a', source: 'ai' },
      { targetNote: note(3), linkKind: 'related', reason: 'b', source: 'ai' },
      { targetNote: note(1), linkKind: 'related', reason: 'c', source: 'ai' },
    ]
    const open = openLinkProposals(proposals, [link], 'note-1')
    expect(open.map((proposal) => proposal.targetNote.noteId)).toEqual(['note-3'])
  })
})

describe('rewrite helpers', () => {
  test('replaces only the selected range and reports the inserted range', () => {
    const result = applyRewrite('alpha beta gamma', { start: 6, end: 10 }, 'BETA!')
    expect(result.body).toBe('alpha BETA! gamma')
    expect(result.range).toEqual({ start: 6, end: 11 })
  })

  test('replaces the whole draft when no valid selection was armed', () => {
    expect(applyRewrite('alpha', undefined, 'omega')).toEqual({ body: 'omega', range: undefined })
    expect(applyRewrite('alpha', { start: 3, end: 3 }, 'omega').body).toBe('omega')
  })

  test('reads the selected text only for a valid range', () => {
    expect(selectedText('alpha beta', { start: 0, end: 5 })).toBe('alpha')
    expect(selectedText('alpha beta', { start: 0, end: 99 })).toBeUndefined()
  })

  test('rejects a rewrite whose draft or selection moved while it was running', () => {
    expect(rewriteResultIsFresh({ currentDraft: 'a', submittedDraft: 'a' })).toBe(true)
    expect(rewriteResultIsFresh({ currentDraft: 'b', submittedDraft: 'a' })).toBe(false)
    expect(rewriteResultIsFresh({
      currentDraft: 'alpha beta',
      submittedDraft: 'alpha beta',
      submittedRange: { start: 0, end: 5 },
      submittedSelectedText: 'alpha',
    })).toBe(true)
    expect(rewriteResultIsFresh({
      currentDraft: 'alpha beta',
      submittedDraft: 'alpha beta',
      submittedRange: { start: 6, end: 10 },
      submittedSelectedText: 'alpha',
    })).toBe(false)
  })

  test('quotes the selection and truncates it at 400 characters', () => {
    const comment = selectionQuestionComment({
      selectedText: 'first\n\nsecond',
      question: '  why?  ',
      answerMarkdown: ' because ',
    })
    expect(comment).toBe('> first\n>\n> second\n\n**Q:** why?\n\n**A:** because')
    const long = selectionQuestionComment({
      selectedText: 'x'.repeat(500),
      question: 'q',
      answerMarkdown: 'a',
    })
    expect(long.startsWith(`> ${'x'.repeat(400)}…`)).toBe(true)
  })
})

describe('reader paging', () => {
  test('walks to the adjacent note inside the loaded window', () => {
    const loaded = window([1, 2, 3])
    expect(adjacentNoteId(loaded, 'note-2', 1)).toBe('note-3')
    expect(adjacentNoteId(loaded, 'note-1', -1)).toBeUndefined()
    expect(adjacentNoteId(loaded, 'missing', 1)).toBeUndefined()
  })

  test('requests another page only near an edge that has more notes', () => {
    const trailing = window([1, 2, 3, 4, 5], { hasMore: true })
    expect(needsLaterPage(trailing, 'note-4')).toBe(true)
    expect(needsLaterPage(trailing, 'note-2')).toBe(false)
    expect(needsLaterPage(window([1, 2, 3, 4, 5]), 'note-5')).toBe(false)
    const leading = window([1, 2, 3], { startOffset: 10, hasEarlier: true })
    expect(needsEarlierPage(leading, 'note-1')).toBe(true)
    expect(needsEarlierPage(leading, 'note-3')).toBe(false)
  })

  test('derives absolute offsets for both edges', () => {
    expect(laterPageOffset(window([1, 2], { startOffset: 10 }))).toBe(12)
    expect(earlierPageRequest(window([1], { startOffset: 10 }), 4)).toEqual({ offset: 6, limit: 4 })
    expect(earlierPageRequest(window([1], { startOffset: 3 }), 25)).toEqual({ offset: 0, limit: 3 })
    expect(earlierPageRequest(window([1]), 25)).toBeUndefined()
  })

  test('appends without duplicating and clears hasMore on a short page', () => {
    const appended = appendReaderPage(window([1, 2], { hasMore: true }), [note(2), note(3)], 2)
    expect(appended.notes.map((value) => value.noteId)).toEqual(['note-1', 'note-2', 'note-3'])
    expect(appended.hasMore).toBe(true)
    expect(appendReaderPage(window([1], { hasMore: true }), [note(2)], 25).hasMore).toBe(false)
    expect(appendReaderPage(window([1], { hasMore: true }), [note(1)], 1).hasMore).toBe(false)
  })

  test('prepends and rebases the window start offset', () => {
    const prepended = prependReaderPage(window([3], { startOffset: 2, hasEarlier: true }), [note(1), note(2)], 0)
    expect(prepended.notes.map((value) => value.noteId)).toEqual(['note-1', 'note-2', 'note-3'])
    expect(prepended.startOffset).toBe(0)
    expect(prepended.hasEarlier).toBe(false)
  })

  test('replaces a saved note in place and leaves unknown notes alone', () => {
    const saved = { ...note(2), bodyMarkdown: 'edited' }
    expect(replaceReaderNote(window([1, 2]), saved).notes[1]?.bodyMarkdown).toBe('edited')
    expect(replaceReaderNote(window([1]), saved).notes).toHaveLength(1)
  })

  test('labels the reader position, marking partially loaded notebooks', () => {
    expect(readerPositionLabel(window([1, 2, 3]), 'note-2')).toBe('2 of 3')
    expect(readerPositionLabel(window([1, 2], { startOffset: 4, hasMore: true }), 'note-1')).toBe('5 of 6+')
    expect(readerPositionLabel(window([1]), 'missing')).toBeUndefined()
  })
})

describe('attachments and tags', () => {
  test('reads both the nested and the flat attachment shape', () => {
    const nested = attachmentView({
      noteId: 'note-1',
      role: 'sourcePageImage',
      file: { fileId: 'file-1', mediaType: 'image/png', byteSize: 12, originalFilename: 'page.png' },
    })
    expect(nested).toEqual({
      fileId: 'file-1',
      mediaType: 'image/png',
      byteSize: 12,
      originalFilename: 'page.png',
      role: 'sourcePageImage',
    })
    expect(attachmentView({ fileId: 'file-2', mediaType: 'text/plain', byteSize: 3 })?.fileId).toBe('file-2')
    expect(attachmentView({ role: 'attachment' })).toBeUndefined()
    expect(attachmentView(null)).toBeUndefined()
  })

  test('reads note tag names defensively', () => {
    expect(noteTagNames({ tags: [{ tag: { name: 'alpha' } }, { tag: {} }, {}] })).toEqual(['alpha'])
    expect(noteTagNames({})).toEqual([])
    expect(noteTagNames(undefined)).toEqual([])
  })
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

describe('error messages', () => {
  test('explains an unconfigured assistant provider', () => {
    const message = workspaceErrorMessage(new APIError('nope', 409, 'provider_not_configured'))
    expect(message).toContain('riela workflow provider')
  })

  test('passes other failures through', () => {
    expect(workspaceErrorMessage(new APIError('boom', 400, 'note_operation_failed'))).toBe('boom')
    expect(workspaceErrorMessage(new Error('offline'))).toBe('offline')
  })
})
