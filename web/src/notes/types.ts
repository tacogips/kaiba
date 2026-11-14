import type { CommentId, FileId, NoteId, NotebookId, TagClassId, TagId } from './ids'

export type NoteListSort = 'updatedAtDesc' | 'title' | 'createdAtDesc' | 'createdAtAsc'

export interface ControlResult {
  accepted: boolean
  status: string
  diagnostics: string[]
}

export interface NoteTag {
  tagId: TagId
  name: string
  classId: TagClassId | null
  parentTagId: TagId | null
  isSystem: boolean
  createdAt: string
}

export interface NoteTagClass {
  classId: TagClassId
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
  notebookId: NotebookId
  title: string
  readOnly: boolean
  createdAt: string
  updatedAt: string
  tags: NoteTagAssignment[]
  firstNotePreview?: string | null
  noteCount?: number | null
}

export interface Note {
  noteId: NoteId
  notebookId: NotebookId
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
  fileId: FileId
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
  noteId: NoteId
  file: NoteFileRecord
  role: string
  position: number
}

/** A memo: anchored to a note (`noteId` set) or to a whole notebook
 * (`noteId` null); `notebookId` names the containing notebook either way. */
export interface NoteComment {
  commentId: CommentId
  noteId: NoteId | null
  notebookId?: NotebookId | null
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
  memoNotebookId: NotebookId | null
}

/** A memo in a tag's cross-notebook history, attributed with the titles of
 * its anchoring note/notebook. */
export interface TagComment {
  comment: NoteComment
  noteTitle: string | null
  notebookTitle: string | null
}

export interface NoteGraphNeighbor {
  seedNoteId: NoteId
  note: Note
  edgeKind: string
  weight: number
  hopCount: number
  pathNoteIds: NoteId[]
}

export interface AgentConversation {
  notebookId: NotebookId
  title: string
  updatedAt: string
  turnCount: number
  /** Null for a notebook-scoped conversation (started with no note selected). */
  subjectNoteId: NoteId | null
  subjectNotebookId?: NotebookId | null
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
  /** The server evicted retained chunks; refresh the durable conversation. */
  resync: boolean
}

export interface AgentChatMessageResult {
  conversationNotebookId: NotebookId | null
  turnNoteId: NoteId | null
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

/** Personal-agent credential as the server reports it: the key itself is
 * write-only, only its last four characters come back as `keyHint`. */
export interface UserAgentCredentialSummary {
  provider: string
  keyHint: string
  baseURL: string | null
  defaultModel: string
  enabled: boolean
  updatedAt: string
}

export interface UserAgentCredentialState {
  featureEnabled: boolean
  customBaseURLAllowed: boolean
  providers: string[]
  credential: UserAgentCredentialSummary | null
}

export interface SetUserAgentCredentialInput {
  provider: string
  apiKey: string
  defaultModel: string
  baseURL?: string | null
  enabled?: boolean
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
