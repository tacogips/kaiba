import type { AgentConversation, Note, NoteComment } from './types'
import { chatTurns, type ChatTurn } from './chatState'

// The unified memo feature: plain memos (comments) and agent chat turns are one
// timeline, ordered by creation time. Everything here is pure so the merge and
// selection rules are testable without a DOM.

export type MemoTimelineEntry =
  | { kind: 'memo'; createdAt: string; memo: NoteComment }
  | { kind: 'turn'; createdAt: string; turn: ChatTurn; conversationId: string }

export function memoTimeline(
  memos: NoteComment[],
  turnsByConversation: Array<{ conversationId: string; turns: ChatTurn[] }>,
): MemoTimelineEntry[] {
  const entries: MemoTimelineEntry[] = memos.map((memo) => ({
    kind: 'memo',
    createdAt: memo.createdAt,
    memo,
  }))
  for (const conversation of turnsByConversation) {
    for (const turn of conversation.turns) {
      entries.push({
        kind: 'turn',
        createdAt: turn.createdAt,
        turn,
        conversationId: conversation.conversationId,
      })
    }
  }
  // Stable by creation time; equal timestamps keep memos before turns so a
  // memo written just before a question reads in that order.
  return entries.sort((left, right) =>
    left.createdAt < right.createdAt ? -1 : left.createdAt > right.createdAt ? 1 : 0)
}

/** The conversation a new "Send" continues: the most recently updated one. */
export function latestConversationId(conversations: AgentConversation[]): string | undefined {
  let latest: AgentConversation | undefined
  for (const conversation of conversations) {
    if (!latest || conversation.updatedAt > latest.updatedAt) latest = conversation
  }
  return latest?.notebookId
}

/** The turn a streaming poll should follow: the newest pending one. */
export function pendingStreamTurn(entries: MemoTimelineEntry[]): ChatTurn | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index]
    if (entry?.kind === 'turn' && entry.turn.status === 'pending') return entry.turn
  }
  return undefined
}

export function conversationTurns(notes: Note[]): ChatTurn[] {
  return chatTurns(notes)
}

/** Note titles by id, for attributing memos in the notebook-wide view. */
export function noteTitlesById(notes: Note[]): Map<string, string> {
  const titles = new Map<string, string>()
  for (const note of notes) {
    titles.set(note.noteId, note.title ?? `p.${note.noteNumber}`)
  }
  return titles
}
