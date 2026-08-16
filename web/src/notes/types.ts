export type NoteListSort = 'updatedAtDesc' | 'title' | 'createdAtDesc' | 'createdAtAsc'

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

/** A file stored for a note attachment. Only the fields the web reader needs
 * are queried; bytes are served separately via `GET /files/<fileId>`. */
export interface NoteFileRecord {
  fileId: string
  storageKind: string
  mediaType: string
  byteSize: number
  sha256: string
  originalFilename: string | null
  createdAt: string
}

/** A file attached to a note. Role "source-page-image" is a captured page of
 * the imported source document (position = 1-based page number); role
 * "embedded" is an image that appeared on those pages. */
export interface NoteFileAttachment {
  noteId: string
  file: NoteFileRecord
  role: string
  position: number
}

/** A memo: anchored to a note (`noteId` set) or to a whole notebook
 * (`noteId` null); `notebookId` names the containing notebook either way. */
export interface NoteComment {
  commentId: string
  noteId: string | null
  notebookId?: string | null
  bodyMarkdown: string
  author: string
  createdAt: string
}

/** Cross-notebook tag detail (design-docs/specs/tag-detail-pane.md). */
export interface TagDetail {
  tag: NoteTag
  tagClass: NoteTagClass | null
  noteCount: number
  notebookCount: number
  /** The tag's memo/chat notebook, once one has been created. */
  memoNotebookId: string | null
}

/** A memo in a tag's cross-notebook history, attributed with the titles of
 * its anchoring note/notebook. */
export interface TagComment {
  comment: NoteComment
  noteTitle: string | null
  notebookTitle: string | null
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
  /** Null for a notebook-scoped conversation (started with no note selected). */
  subjectNoteId: string | null
  subjectNotebookId?: string | null
}

export interface AgenticSearchResult {
  /** "ok", "agent-unavailable", or "failed". */
  status: string
  answerMarkdown: string | null
}

/** One long-poll response of the agent reply chunk stream. */
export interface AgentReplyStreamPoll {
  cursor: number
  chunks: string[]
  done: boolean
  status: string | null
  message: string | null
}

export interface AgentChatMessageResult {
  conversationNotebookId: string | null
  turnNoteId: string | null
  agentStatus: string
}

export interface AgentChatAttachmentInput {
  contentBase64: string
  mediaType: string
  originalFilename: string
}

export interface AgentModel {
  modelId: string
  displayName?: string | null
  description?: string | null
}

export interface AgentModelsResult {
  models: AgentModel[]
  discoveryAvailable: boolean
  configuredModel: string | null
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
