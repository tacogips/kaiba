import { noteId as asNoteId, notebookId as asNotebookId } from './ids'
import { describe, expect, test } from 'bun:test'
import {
  assistantMarkdown,
  chatTurns,
  newIdempotencyKey,
  parseChatTurn,
  turnStatusLabel,
} from './chatState'
import type { Note } from './types'

function turnNote(overrides: Partial<Note> & { noteNumber: number }): Note {
  return {
    noteId: asNoteId(`note-${overrides.noteNumber}`),
    notebookId: asNotebookId('conv-1'),
    title: `Chat Turn ${overrides.noteNumber}`,
    bodyMarkdown: '',
    readOnly: false,
    createdAt: '2026-08-12T00:00:00Z',
    updatedAt: '2026-08-12T00:00:00Z',
    ...overrides,
  }
}

function body(user: string, agent: string): string {
  return `# Chat Turn 1\n\n## User\n${user}\n\n## Agent\n${agent}`
}

function meta(chat: Record<string, unknown>): string {
  return JSON.stringify({ kaibaChat: chat })
}

describe('assistant extraction', () => {
  test('reads the reply after the agent heading', () => {
    expect(assistantMarkdown(body('question', 'The answer.\n\nWith detail.')))
      .toBe('The answer.\n\nWith detail.')
  })

  test('treats the placeholder and an empty section as no reply', () => {
    expect(assistantMarkdown(body('question', '_(no reply yet)_'))).toBeUndefined()
    expect(assistantMarkdown(body('question', ''))).toBeUndefined()
  })

  test('a body without the agent heading has no reply', () => {
    expect(assistantMarkdown('# Chat Turn 1\n\n## User\nquestion\n')).toBeUndefined()
  })
})

describe('turn status parsing', () => {
  test('pending turn keeps the user message from metadata', () => {
    const turn = parseChatTurn(turnNote({
      noteNumber: 1,
      bodyMarkdown: body('typed question', '_(no reply yet)_'),
      metaJSON: meta({ status: 'pending', userMarkdown: 'typed question' }),
    }))
    expect(turn.status).toBe('pending')
    expect(turn.userMarkdown).toBe('typed question')
    expect(turn.assistantMarkdown).toBeUndefined()
  })

  test('unavailable turn is unanswered but not pending', () => {
    const turn = parseChatTurn(turnNote({
      noteNumber: 1,
      bodyMarkdown: body('typed question', '_(no reply yet)_'),
      metaJSON: meta({ status: 'unavailable', userMarkdown: 'typed question' }),
    }))
    expect(turn.status).toBe('unavailable')
    expect(turnStatusLabel(turn.status)).toBe('Unanswered')
  })

  test('answered turn carries the reply', () => {
    const turn = parseChatTurn(turnNote({
      noteNumber: 2,
      bodyMarkdown: body('question', 'the reply'),
      metaJSON: meta({ status: 'answered', userMarkdown: 'question' }),
    }))
    expect(turn.status).toBe('answered')
    expect(turn.assistantMarkdown).toBe('the reply')
    expect(turn.error).toBeUndefined()
  })

  test('failed turn surfaces the recorded error', () => {
    const turn = parseChatTurn(turnNote({
      noteNumber: 3,
      bodyMarkdown: body('question', '_(no reply yet)_'),
      metaJSON: meta({ status: 'failed', userMarkdown: 'question', error: 'agent timed out' }),
    }))
    expect(turn.status).toBe('failed')
    expect(turn.error).toBe('agent timed out')
  })

  test('unreadable metadata falls back to the body', () => {
    const answered = parseChatTurn(turnNote({
      noteNumber: 1,
      bodyMarkdown: body('question from body', 'the reply'),
      metaJSON: 'not json',
    }))
    expect(answered.status).toBe('answered')
    expect(answered.userMarkdown).toBe('question from body')
    expect(answered.assistantMarkdown).toBe('the reply')

    const unanswered = parseChatTurn(turnNote({
      noteNumber: 2,
      bodyMarkdown: body('question from body', '_(no reply yet)_'),
      metaJSON: null,
    }))
    expect(unanswered.status).toBe('pending')
    expect(unanswered.userMarkdown).toBe('question from body')
  })

  test('an unknown status string is treated as unfinished', () => {
    const turn = parseChatTurn(turnNote({
      noteNumber: 1,
      bodyMarkdown: body('question', '_(no reply yet)_'),
      metaJSON: meta({ status: 'quantum', userMarkdown: 'question' }),
    }))
    expect(turn.status).toBe('pending')
  })
})

describe('transcript assembly', () => {
  test('orders turns by note number regardless of fetch order', () => {
    const turns = chatTurns([
      turnNote({ noteNumber: 3, bodyMarkdown: body('third', 'c') }),
      turnNote({ noteNumber: 1, bodyMarkdown: body('first', 'a') }),
      turnNote({ noteNumber: 2, bodyMarkdown: body('second', 'b') }),
    ])
    expect(turns.map((turn) => turn.userMarkdown)).toEqual(['first', 'second', 'third'])
  })

})

describe('send status', () => {
  test('every retry gets a fresh idempotency key', () => {
    let counter = 0
    const first = newIdempotencyKey(() => { counter += 1; return counter / 10 })
    const second = newIdempotencyKey(() => { counter += 1; return counter / 10 })
    expect(first).not.toBe(second)
    expect(first.startsWith('kaiba-web-')).toBe(true)
  })
})
