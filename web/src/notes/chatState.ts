import type { Note } from './types'
import type { NoteId } from './ids'

// Agent chat turns are ordinary notes in a conversation notebook: the request
// and its status live in `metaJSON.kaibaChat`, the reply in the body after the
// "## Agent" heading. Both are written by the server and read here defensively —
// a turn with unreadable metadata still renders its body rather than vanishing.

export type ChatTurnStatus = 'pending' | 'answered' | 'failed' | 'unavailable'

export interface ChatTurn {
  noteId: NoteId
  noteNumber: number
  status: ChatTurnStatus
  userMarkdown: string
  assistantMarkdown?: string
  error?: string
  createdAt: string
  /** "edit" marks a turn whose reply rewrote the subject note. */
  mode?: 'memo' | 'edit'
}

const assistantHeading = '\n## Agent\n'
const userHeading = '\n## User\n'
const noReplyPlaceholder = '_(no reply yet)_'

export function assistantMarkdown(bodyMarkdown: string): string | undefined {
  const index = bodyMarkdown.indexOf(assistantHeading)
  if (index < 0) return undefined
  const assistant = bodyMarkdown.slice(index + assistantHeading.length).trim()
  return assistant.length === 0 || assistant === noReplyPlaceholder ? undefined : assistant
}

/** The user's message, preferring the metadata copy and falling back to the
 * "## User" section of the body when metadata is missing. */
export function userMarkdown(note: Pick<Note, 'bodyMarkdown'>, fromMeta?: string): string {
  if (fromMeta && fromMeta.trim().length > 0) return fromMeta
  const start = note.bodyMarkdown.indexOf(userHeading)
  if (start < 0) return ''
  const rest = note.bodyMarkdown.slice(start + userHeading.length)
  const end = rest.indexOf(assistantHeading)
  return (end < 0 ? rest : rest.slice(0, end)).trim()
}

export function parseChatTurn(note: Note): ChatTurn {
  const chat = chatMeta(note.metaJSON)
  const reply = assistantMarkdown(note.bodyMarkdown)
  return {
    noteId: note.noteId,
    noteNumber: note.noteNumber,
    status: turnStatus(chat?.status, reply !== undefined),
    userMarkdown: userMarkdown(note, chat?.userMarkdown),
    ...(reply === undefined ? {} : { assistantMarkdown: reply }),
    ...(chat?.error ? { error: chat.error } : {}),
    createdAt: note.createdAt,
    ...(chat?.mode ? { mode: chat.mode } : {}),
  }
}

/** Turns in reading order (oldest first), which is the note-number order the
 * server assigns as turns are appended. */
export function chatTurns(notes: Note[]): ChatTurn[] {
  return [...notes]
    .sort((left, right) => left.noteNumber - right.noteNumber)
    .map(parseChatTurn)
}

export function turnStatusLabel(status: ChatTurnStatus): string {
  switch (status) {
    case 'pending': return 'Waiting for the agent'
    case 'unavailable': return 'Unanswered'
    case 'failed': return 'Failed'
    default: return 'Answered'
  }
}

/** A stable idempotency key per send attempt; a retry deliberately uses a fresh
 * key so the resend is persisted as its own turn. */
export function newIdempotencyKey(random: () => number = Math.random): string {
  const suffix = Math.floor(random() * 0xffffffff).toString(16).padStart(8, '0')
  return `kaiba-web-${Date.now().toString(36)}-${suffix}`
}

interface ChatMeta {
  status?: string
  userMarkdown?: string
  error?: string
  mode?: 'memo' | 'edit'
}

function chatMeta(metaJSON: string | null | undefined): ChatMeta | undefined {
  if (!metaJSON) return undefined
  let parsed: unknown
  try {
    parsed = JSON.parse(metaJSON)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null) return undefined
  const chat = (parsed as Record<string, unknown>).kaibaChat
  if (typeof chat !== 'object' || chat === null) return undefined
  const record = chat as Record<string, unknown>
  return {
    ...(typeof record.status === 'string' ? { status: record.status } : {}),
    ...(typeof record.userMarkdown === 'string' ? { userMarkdown: record.userMarkdown } : {}),
    ...(typeof record.error === 'string' && record.error.length > 0 ? { error: record.error } : {}),
    ...(record.mode === 'memo' || record.mode === 'edit' ? { mode: record.mode } : {}),
  }
}

function turnStatus(raw: string | undefined, hasReply: boolean): ChatTurnStatus {
  switch (raw) {
    case 'pending':
    case 'answered':
    case 'failed':
    case 'unavailable':
      return raw
    default:
      // Unknown or missing metadata: the body is the only evidence left.
      return hasReply ? 'answered' : 'pending'
  }
}
