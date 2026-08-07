// Pagination bounds enforced by NoteGraphQLDocumentExecutor for every list and
// search field (notebooks, notes, searchNotes): `limit` must be an integer in
// 0...200 (0 returns an empty list) and `offset` an integer in 0...1_000_000.
// Graph fields (noteGraphNeighbors, proposeNoteLinks) accept `limit` only in
// 0...20 — the bounded traversal's node cap. Any other value (out of range,
// non-integral, or the wrong type) is rejected with an invalidVariable error
// rather than silently clamped.
let graphQLNoteSchemaContract = """
type NoteTag { tagId: String!, name: String!, classId: String, parentTagId: String, statusSetId: String, isSystem: Boolean!, createdAt: String! }
type NoteTagClass { classId: String!, label: String!, description: String, isSystem: Boolean!, createdAt: String! }
type NoteTagAssignment { tag: NoteTag!, provenance: String!, assignedBy: String, deletable: Boolean!, createdAt: String! }
enum KanbanStatusCategory { none pending progress review done }
type KanbanStatus { statusId: String!, name: String!, category: KanbanStatusCategory!, position: Int! }
type KanbanStatusSet { setId: String!, name: String!, isSystem: Boolean!, statuses: [KanbanStatus!]! }
type KanbanStatusSetQueryPayload { result: ControlPlaneResult!, value: KanbanStatusSet }
type KanbanStatusSetsQueryPayload { result: ControlPlaneResult!, value: [KanbanStatusSet!] }
input KanbanStatusInput { statusId: String, name: String!, category: KanbanStatusCategory! }
input KanbanStatusReassignmentInput { removedName: String!, reassignTo: String! }
type Notebook {
  notebookId: String!, title: String!, progress: String!, readOnly: Boolean!
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
type NoteComment { commentId: String!, noteId: String!, bodyMarkdown: String!, author: String!, createdAt: String! }
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
type NoteAutoActionsQueryPayload { result: ControlPlaneResult!, value: [NoteAutoAction!] }
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
input LinkNotesInput { fromNoteId: String!, toNoteId: String!, linkKind: String, provenance: String }
input AttachNoteFileInput { noteId: String!, contentBase64: String!, role: String, mediaType: String!, originalFilename: String, position: Int }
input ConfigureNoteAutoActionInput { actionId: String!, trigger: String!, workflowId: String!, filterJSON: String, enabled: Boolean, position: Int }
input NoteConversationTurnInput { userMarkdown: String!, assistantMarkdown: String!, sourceNoteIds: [String!] }
input SaveNoteConversationInput { title: String!, transcript: [NoteConversationTurnInput!]!, assignedBy: String }
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
