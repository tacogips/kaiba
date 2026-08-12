import { describe, expect, test } from 'bun:test'
import {
  latestConversationId,
  memoTimeline,
  noteTitlesById,
  pendingStreamTurn,
} from './memoTimeline'
import type { ChatTurn } from './chatState'
import type { AgentConversation, Note, NoteComment } from './types'

function memo(commentId: string, createdAt: string, noteId: string | null = 'note-1'): NoteComment {
  return { commentId, noteId, notebookId: 'nb-1', bodyMarkdown: 'm', author: 'user', createdAt }
}

function turn(noteId: string, createdAt: string, status: ChatTurn['status'] = 'answered'): ChatTurn {
  return { noteId, noteNumber: 1, status, userMarkdown: 'q', createdAt }
}

describe('memo timeline merge', () => {
  test('interleaves memos and turns by creation time', () => {
    const entries = memoTimeline(
      [memo('c-2', '2026-01-02T00:00:00Z'), memo('c-4', '2026-01-04T00:00:00Z')],
      [
        { conversationId: 'conv-1', turns: [turn('t-1', '2026-01-01T00:00:00Z')] },
        { conversationId: 'conv-2', turns: [turn('t-3', '2026-01-03T00:00:00Z')] },
      ],
    )
    expect(entries.map((entry) => entry.kind)).toEqual(['turn', 'memo', 'turn', 'memo'])
    expect(entries.map((entry) => entry.createdAt)).toEqual([
      '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z', '2026-01-03T00:00:00Z', '2026-01-04T00:00:00Z',
    ])
  })

  test('a memo written at the same instant sorts before the turn', () => {
    const entries = memoTimeline(
      [memo('c-1', '2026-01-01T00:00:00Z')],
      [{ conversationId: 'conv-1', turns: [turn('t-1', '2026-01-01T00:00:00Z')] }],
    )
    expect(entries[0]?.kind).toBe('memo')
  })
})

describe('conversation selection', () => {
  const conversation = (notebookId: string, updatedAt: string): AgentConversation =>
    ({ notebookId, title: 't', updatedAt, turnCount: 1, subjectNoteId: null, subjectNotebookId: 'nb-1' })

  test('send continues the most recently updated conversation', () => {
    expect(latestConversationId([
      conversation('conv-1', '2026-01-01T00:00:00Z'),
      conversation('conv-2', '2026-01-03T00:00:00Z'),
      conversation('conv-3', '2026-01-02T00:00:00Z'),
    ])).toBe('conv-2')
    expect(latestConversationId([])).toBeUndefined()
  })

  test('the stream follows the newest pending turn only', () => {
    const entries = memoTimeline([], [{
      conversationId: 'conv-1',
      turns: [
        turn('t-1', '2026-01-01T00:00:00Z', 'answered'),
        turn('t-2', '2026-01-02T00:00:00Z', 'pending'),
        turn('t-3', '2026-01-03T00:00:00Z', 'failed'),
      ],
    }])
    expect(pendingStreamTurn(entries)?.noteId).toBe('t-2')
    expect(pendingStreamTurn(memoTimeline([memo('c-1', '2026-01-01T00:00:00Z')], []))).toBeUndefined()
  })
})

describe('memo attribution', () => {
  test('maps note ids to titles with a page fallback', () => {
    const notes: Note[] = [
      { noteId: 'n-1', notebookId: 'nb-1', noteNumber: 1, title: 'Alpha', bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' },
      { noteId: 'n-2', notebookId: 'nb-1', noteNumber: 2, title: null, bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' },
    ]
    const titles = noteTitlesById(notes)
    expect(titles.get('n-1')).toBe('Alpha')
    expect(titles.get('n-2')).toBe('p.2')
  })
})
