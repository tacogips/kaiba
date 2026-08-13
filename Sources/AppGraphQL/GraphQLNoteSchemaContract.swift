// Pagination bounds enforced by NoteGraphQLDocumentExecutor for every list and
// search field (notebooks, notes, searchNotes): `limit` must be an integer in
// 0...200 (0 returns an empty list) and `offset` an integer in 0...1_000_000.
// Graph fields (noteGraphNeighbors, proposeNoteLinks) accept `limit` only in
// 0...20 — the bounded traversal's node cap. Any other value (out of range,
// non-integral, or the wrong type) is rejected with an invalidVariable error
// rather than silently clamped.
let graphQLNoteSchemaContract = """
type NoteTag { tagId: String!, name: String!, classId: String, parentTagId: String, isSystem: Boolean!, createdAt: String! }
type NoteTagClass { classId: String!, label: String!, description: String, isSystem: Boolean!, createdAt: String! }
type NoteTagAssignment { tag: NoteTag!, provenance: String!, assignedBy: String, deletable: Boolean!, createdAt: String! }
type Notebook {
  notebookId: String!, title: String!, readOnly: Boolean!
  createdAt: String!, updatedAt: String!, metaJSON: String
  tags: [NoteTagAssignment!]!, firstNotePreview: String, noteCount: Int
}
type Note { noteId: String!, notebookId: String!, noteNumber: Int!, title: String, bodyMarkdown: String!, readOnly: Boolean!, createdAt: String!, updatedAt: String!, metaJSON: String, tags: [NoteTagAssignment!]! }
type NoteFile {
  fileId: String!
  storageKind: String!
  localPath: String
  s3Profile: String
  s3Bucket: String
  s3Key: String
  mediaType: String!
  byteSize: Int!
  sha256: String!
  originalFilename: String
  createdAt: String!
  migratedAt: String
}
type NoteFileAttachment { noteId: String!, file: NoteFile!, role: String!, position: Int! }
type NoteComment { commentId: String!, noteId: String, notebookId: String, bodyMarkdown: String!, author: String!, createdAt: String! }
type NoteLink { fromNoteId: String!, toNoteId: String!, linkKind: String!, provenance: String!, createdAt: String! }
type NoteSearchResult { note: Note!, snippet: String!, rank: Float!, matchedTags: [NoteTag!]!, isLinkedNeighbor: Boolean! }
type NoteGraphNeighbor { seedNoteId: String!, note: Note!, edgeKind: String!, weight: Float!, hopCount: Int!, pathNoteIds: [String!]! }
type NoteLinkProposal { targetNote: Note!, targetNoteId: String!, linkKind: String!, reason: String!, source: String! }
type NoteAutoAction { actionId: String!, trigger: String!, workflowId: String!, filterJSON: String, enabled: Boolean!, position: Int!, createdAt: String! }
enum NoteListSort { createdAtDesc createdAtAsc updatedAtDesc title }
type NoteQueryPayload { result: ControlPlaneResult!, value: Note }
type NotebookQueryPayload { result: ControlPlaneResult!, value: Notebook }
type NotebooksQueryPayload { result: ControlPlaneResult!, value: [Notebook!] }
type NotesQueryPayload { result: ControlPlaneResult!, value: [Note!] }
type NoteSearchQueryPayload { result: ControlPlaneResult!, value: [NoteSearchResult!] }
type NoteGraphNeighborsQueryPayload { result: ControlPlaneResult!, value: [NoteGraphNeighbor!] }
type NoteLinkProposalQueryPayload { result: ControlPlaneResult!, value: [NoteLinkProposal!] }
type NoteTagsQueryPayload { result: ControlPlaneResult!, value: [NoteTag!] }
type NoteTagClassesQueryPayload { result: ControlPlaneResult!, value: [NoteTagClass!] }
type NoteFileQueryPayload { result: ControlPlaneResult!, value: NoteFile }
type NoteFilesQueryPayload { result: ControlPlaneResult!, value: [NoteFileAttachment!] }
type NoteAutoActionsQueryPayload { result: ControlPlaneResult!, value: [NoteAutoAction!] }
type NoteCommentsQueryPayload { result: ControlPlaneResult!, value: [NoteComment!] }
# Cross-notebook tag detail surface (design-docs/specs/tag-detail-pane.md).
# tagComments aggregates memos of notes/notebooks carrying the tag (descendant
# tags included), newest first; ensureTagMemoNotebook (a NoteMutationPayload
# mutation) lazily finds or creates the tag's memo/chat notebook.
type TagDetail { tag: NoteTag!, tagClass: NoteTagClass, noteCount: Int!, notebookCount: Int!, memoNotebookId: String }
type TagDetailQueryPayload { result: ControlPlaneResult!, value: TagDetail }
type TagComment { comment: NoteComment!, noteTitle: String, notebookTitle: String }
type TagCommentsQueryPayload { result: ControlPlaneResult!, value: [TagComment!] }
input NoteTagInput { name: String!, classId: String }
input CreateNoteInput {
  notebookId: String
  notebookTitle: String
  title: String
  bodyMarkdown: String!
  readOnly: Boolean
  tags: [NoteTagInput!]
  provenance: String
  assignedBy: String
  metaJSON: String
  originatingActionId: String
}
input CreateNotebookInput { title: String!, kindTagName: String, folderPath: [String!], metaJSON: String, originatingActionId: String }
input DefineNoteTagClassInput { classId: String!, label: String!, description: String }
input DefineNoteTagInput { name: String!, classId: String, parentTagId: String, createOnly: Boolean }
# updateNote re-derives the stored title from bodyMarkdown, replacing any previously explicit title.
input UpdateNoteInput { noteId: String!, bodyMarkdown: String!, originatingActionId: String }
input ApplyNoteTagsInput { noteId: String!, tags: [NoteTagInput!]!, provenance: String, assignedBy: String }
input ApplyNotebookTagsInput { notebookId: String!, tags: [String!]!, provenance: String, assignedBy: String }
input ApplyNotebookTagIdsInput { notebookId: String!, tagIds: [String!]!, provenance: String, assignedBy: String }
input AddNoteCommentInput { noteId: String!, bodyMarkdown: String!, author: String }
input AddNotebookCommentInput { notebookId: String!, bodyMarkdown: String!, author: String }
input LinkNotesInput { fromNoteId: String!, toNoteId: String!, linkKind: String, provenance: String }
input AttachNoteFileInput { noteId: String!, contentBase64: String!, role: String, mediaType: String!, originalFilename: String, position: Int }
input ConfigureNoteAutoActionInput { actionId: String!, trigger: String!, workflowId: String!, filterJSON: String, enabled: Boolean, position: Int }
input NoteConversationTurnInput { userMarkdown: String!, assistantMarkdown: String!, sourceNoteIds: [String!] }
input SaveNoteConversationInput { title: String!, transcript: [NoteConversationTurnInput!]!, assignedBy: String }
type AgentConversation { notebookId: String!, title: String!, updatedAt: String!, turnCount: Int!, subjectNoteId: String, subjectNotebookId: String }
# App settings are JSON documents keyed by name (e.g. "web"), stored in the
# note store's sqlite so preferences follow the store across clients.
type AppSettingPayload { result: ControlPlaneResult!, key: String!, valueJSON: String }
input SetAppSettingInput { key: String!, valueJSON: String! }
# agenticSearch answers a search question with the configured agent runtime;
# the agent receives the kaiba CLI search usage plus a grep pass as context.
# status "agent-unavailable" means no runtime is configured.
type AgenticSearchPayload { result: ControlPlaneResult!, status: String!, answerMarkdown: String }
type AgentConversationsQueryPayload { result: ControlPlaneResult!, value: [AgentConversation!] }
type AgentModel { modelId: String!, displayName: String, description: String }
type AgentModelsPayload { result: ControlPlaneResult!, models: [AgentModel!]!, discoveryAvailable: Boolean!, configuredModel: String }
# sendAgentChatMessage persists the user turn even when no agent runtime is
# available (agentStatus "agent-unavailable"); replies arrive asynchronously via
# the note change feed once the chat-reply auto-action completes the turn.
input AgentChatAttachmentInput { contentBase64: String!, mediaType: String!, originalFilename: String! }
input SendAgentChatMessageInput { subjectNoteId: String, subjectNotebookId: String, conversationNotebookId: String, userMarkdown: String!, idempotencyKey: String, model: String, attachments: [AgentChatAttachmentInput!] }
type AgentChatMessagePayload { result: ControlPlaneResult!, conversationNotebookId: String, turnNoteId: String, agentStatus: String! }
input RequestTagExtractionInput { noteId: String, notebookId: String }
type TagExtractionRequestPayload { result: ControlPlaneResult!, status: String! }
# requestNotebookTranslation creates a pending notebook-kind:translation
# notebook and queues the run; translated notes arrive asynchronously via the
# note change feed. status "agent-unavailable" means nothing was created.
input RequestNotebookTranslationInput { notebookId: String!, targetLanguage: String!, title: String }
type NotebookTranslationRequestPayload { result: ControlPlaneResult!, translationNotebookId: String, status: String! }
input MigrateNoteFileStorageInput {
  fileId: String!
  s3ProfileName: String!
}
input MigrateAllNoteFilesInput {
  s3ProfileName: String!
}
type NoteFileMigrationFailure { fileId: String!, message: String! }
type NoteFileMigrationPayload { result: ControlPlaneResult!, migrated: [NoteFile!]!, failures: [NoteFileMigrationFailure!]!, cleanupFailures: [NoteFileMigrationFailure!]! }
# reclaimNoteFileStorage garbage-collects unreferenced file rows/blobs. graceHours
# (default 24) keeps blobs and stray temp files younger than that window; s3ProfileName
# names an allowlisted profile so orphaned S3 objects can be deleted (optional).
input ReclaimNoteFileStorageInput { graceHours: Int, s3ProfileName: String }
type NoteFileReclamationPayload { result: ControlPlaneResult!, deletedFileIds: [String!]!, sweptPaths: [String!]! }
type NoteMutationPayload {
  result: ControlPlaneResult!
  note: Note
  notebook: Notebook
  notes: [Note!]!
  tag: NoteTag
  tagClass: NoteTagClass
  file: NoteFile
  comment: NoteComment
  link: NoteLink
  autoAction: NoteAutoAction
}
"""
