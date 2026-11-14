import { commentId as asCommentId, noteId as asNoteId, notebookId as asNotebookId } from './ids'
import { describe, expect, test } from 'bun:test'
import {
  latestConversationId,
  memoTimeline,
  noteTitlesById,
  pendingStreamTurn,
} from './memoTimeline'
import type { ChatTurn } from './chatState'
import type { AgentConversation, Note, NoteComment } from './types'
import type { CommentId, NoteId, NotebookId } from './ids'

function memo(commentId: CommentId, createdAt: string, noteId: NoteId | null = asNoteId('note-1')): NoteComment {
  return { commentId, noteId, notebookId: asNotebookId('nb-1'), bodyMarkdown: 'm', author: 'user', createdAt }
}

function turn(noteId: NoteId, createdAt: string, status: ChatTurn['status'] = 'answered'): ChatTurn {
  return { noteId, noteNumber: 1, status, userMarkdown: 'q', createdAt }
}

describe('memo timeline merge', () => {
  test('interleaves memos and turns by creation time', () => {
    const entries = memoTimeline(
      [memo(asCommentId('c-2'), '2026-01-02T00:00:00Z'), memo(asCommentId('c-4'), '2026-01-04T00:00:00Z')],
      [
        { conversationId: asNotebookId('conv-1'), turns: [turn(asNoteId('t-1'), '2026-01-01T00:00:00Z')] },
        { conversationId: asNotebookId('conv-2'), turns: [turn(asNoteId('t-3'), '2026-01-03T00:00:00Z')] },
      ],
    )
    expect(entries.map((entry) => entry.kind)).toEqual(['turn', 'memo', 'turn', 'memo'])
    expect(entries.map((entry) => entry.createdAt)).toEqual([
      '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z',
    ])
  })

  test('a memo written at the same instant sorts before the turn', () => {
    const entries = memoTimeline(
      [memo(asCommentId('c-1'), '2026-01-01T00:00:00Z')],
      [{ conversationId: asNotebookId('conv-1'), turns: [turn(asNoteId('t-1'), '2026-01-01T00:00:00Z')] }],
    )
    expect(entries[0]?.kind).toBe('memo')
  })
})

describe('conversation selection', () => {
  const conversation = (notebookId: NotebookId, updatedAt: string): AgentConversation =>
    ({ notebookId, title: 't', updatedAt, turnCount: 1, subjectNoteId: null, subjectNotebookId: asNotebookId('nb-1') })

  test('send continues the most recently updated conversation', () => {
    expect(latestConversationId([
      conversation(asNotebookId('conv-1'), '2026-01-01T00:00:00Z'),
      conversation(asNotebookId('conv-2'), '2026-01-03T00:00:00Z'),
      conversation(asNotebookId('conv-3'), '2026-01-02T00:00:00Z'),
    ])).toBe(asNotebookId('conv-2'))
    expect(latestConversationId([])).toBeUndefined()
  })

  test('the stream follows the newest pending turn only', () => {
    const entries = memoTimeline([], [{
      conversationId: asNotebookId('conv-1'),
      turns: [
        turn(asNoteId('t-1'), '2026-01-01T00:00:00Z', 'answered'),
        turn(asNoteId('t-2'), '2026-01-02T00:00:00Z', 'pending'),
        turn(asNoteId('t-3'), '2026-01-03T00:00:00Z', 'failed'),
      ],
    }])
    expect(pendingStreamTurn(entries)?.noteId).toBe(asNoteId('t-2'))
    expect(pendingStreamTurn(memoTimeline([memo(asCommentId('c-1'), '2026-01-01T00:00:00Z')], []))).toBeUndefined()
  })
})

describe('memo attribution', () => {
  test('maps note ids to titles with a page fallback', () => {
    const notes: Note[] = [
      { noteId: asNoteId('n-1'), notebookId: asNotebookId('nb-1'), noteNumber: 1, title: 'Alpha', bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' },
      { noteId: asNoteId('n-2'), notebookId: asNotebookId('nb-1'), noteNumber: 2, title: null, bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' },
    ]
    const titles = noteTitlesById(notes)
    expect(titles.get('n-1')).toBe('Alpha')
    expect(titles.get('n-2')).toBe('p.2')
  })
})
