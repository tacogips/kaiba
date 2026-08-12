export type KanbanStatusCategory = 'none' | 'pending' | 'progress' | 'review' | 'done'

export interface KanbanStatus {
  statusId: string
  name: string
  category: KanbanStatusCategory
  position: number
}

export interface KanbanStatusSet {
  setId: string
  name: string
  isSystem: boolean
  statuses: KanbanStatus[]
}
export type NoteListSort = 'updatedAtDesc' | 'title' | 'createdAtDesc' | 'createdAtAsc'
export type HostMode = 'riela-app' | 'cli-serve'

export interface ControlResult {
  accepted: boolean
  status: string
  diagnostics: string[]
}

export interface NoteTag {
  tagId: string
  name: string
  classId: string | null
  parentTagId: string | null
  statusSetId?: string | null
  isSystem: boolean
  createdAt: string
}

export interface NoteTagClass {
  classId: string
  label: string
  description: string | null
}

export interface NoteTagAssignment {
  tag: NoteTag
  provenance: string
  assignedBy: string | null
  deletable: boolean
  createdAt: string
}

export interface Notebook {
  notebookId: string
  title: string
  progress: string
  readOnly: boolean
  createdAt: string
  updatedAt: string
  tags: NoteTagAssignment[]
  firstNotePreview?: string | null
  noteCount?: number | null
}

export interface Note {
  noteId: string
  notebookId: string
  noteNumber: number
  title: string | null
  bodyMarkdown: string
  readOnly: boolean
  createdAt: string
  updatedAt: string
  /** Present on the single-note query and on chat turn notes. */
  metaJSON?: string | null
  tags?: NoteTagAssignment[]
}

export interface NoteComment {
  commentId: string
  noteId: string
  bodyMarkdown: string
  author: string
  createdAt: string
}

export interface NoteGraphNeighbor {
  seedNoteId: string
  note: Note
  edgeKind: string
  weight: number
  hopCount: number
  pathNoteIds: string[]
}

export interface AgentConversation {
  notebookId: string
  title: string
  updatedAt: string
  turnCount: number
  subjectNoteId: string
}

export interface AgentChatMessageResult {
  conversationNotebookId: string | null
  turnNoteId: string | null
  agentStatus: string
}

export interface NoteSearchResult {
  note: Note
  snippet: string
  rank: number
  matchedTags: NoteTag[]
  isLinkedNeighbor: boolean
}

export interface QueryPayload<T> {
  result: ControlResult
  value: T
}

export interface MutationPayload {
  result: ControlResult
  notebook?: Notebook | null
  tag?: NoteTag | null
  comment?: NoteComment | null
}

export interface GraphQLEnvelope<T> {
  data?: T
  errors?: Array<{ message: string }>
  error?: string
}
