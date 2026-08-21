import Foundation

/// Kaiba's authoritative GraphQL schema contract: the note domain only.
/// Vendored from riela's contract projector with every workflow/manager/
/// control-plane surface removed; `type Query`/`type Mutation` fields stay on
/// one physical line each because contract tests assert those strings.
public enum GraphQLContractProjector {
  public static let schemaContract = """
  scalar JSON
  scalar JSONObject
  \(graphQLNoteSchemaContract)
  type ControlPlaneResult { accepted: Boolean!, status: String!, diagnostics: [String!]! }
  type Query {
    note(noteId: String!): NoteQueryPayload!
    notebook(notebookId: String!): NotebookQueryPayload!
    notebooks(
      limit: Int,
      offset: Int,
      tagFilter: [String!],
      tagFilterGroups: [[String!]!],
      tagFilterIdGroups: [[String!]!],
      sort: NoteListSort,
      createdAfter: String,
      createdBefore: String
    ): NotebooksQueryPayload!
    libraries: NoteLibrariesQueryPayload!
    notes(limit: Int, offset: Int, notebookId: String, tagFilter: [String!]): NotesQueryPayload!
    searchNotes(
      query: String!, tagFilter: [String!], classFilter: [String!], notebookId: String,
      sort: NoteListSort, createdAfter: String, createdBefore: String,
      includeLinked: Boolean, depth: Int, limit: Int, offset: Int
    ): NoteSearchQueryPayload!
    noteGraphNeighbors(noteIds: [String!]!, depth: Int, limit: Int): NoteGraphNeighborsQueryPayload!
    proposeNoteLinks(noteId: String!, limit: Int): NoteLinkProposalQueryPayload!
    tags: NoteTagsQueryPayload!
    tagClasses: NoteTagClassesQueryPayload!
    noteFile(fileId: String!): NoteFileQueryPayload!
    noteFiles(noteId: String!): NoteFilesQueryPayload!
    autoActions: NoteAutoActionsQueryPayload!
    noteConversations(noteId: String!, limit: Int): AgentConversationsQueryPayload!
    notebookConversations(notebookId: String!, limit: Int): AgentConversationsQueryPayload!
    noteComments(noteId: String!): NoteCommentsQueryPayload!
    notebookComments(notebookId: String!): NoteCommentsQueryPayload!
    tagDetail(tagId: String!): TagDetailQueryPayload!
    tagComments(tagId: String!, limit: Int, offset: Int): TagCommentsQueryPayload!
    agentModels: AgentModelsPayload!
    agenticSearch(query: String!, notebookId: String, limit: Int): AgenticSearchPayload!
    appSetting(key: String!): AppSettingPayload!
    actionHistory(limit: Int, beforeSeq: Int): ActionHistoryPayload!
    undoState: UndoStatePayload!
  }
  type Mutation {
    createNote(input: CreateNoteInput!): NoteMutationPayload!
    createNotebook(input: CreateNotebookInput!): NoteMutationPayload!
    defineNoteTagClass(input: DefineNoteTagClassInput!): NoteMutationPayload!
    defineNoteTag(input: DefineNoteTagInput!): NoteMutationPayload!
    updateNote(input: UpdateNoteInput!): NoteMutationPayload!
    deleteNote(noteId: String!): ControlPlaneResult!
    deleteNotebook(notebookId: String!): ControlPlaneResult!
    applyNotebookTags(input: ApplyNotebookTagsInput!): NoteMutationPayload!
    applyNotebookTagIds(input: ApplyNotebookTagIdsInput!): NoteMutationPayload!
    removeNotebookTag(notebookId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    removeNotebookTagById(notebookId: String!, tagId: String!, provenance: String): NoteMutationPayload!
    setNotebookReadOnly(notebookId: String!, readOnly: Boolean!): NoteMutationPayload!
    setNoteReadOnly(noteId: String!, readOnly: Boolean!): NoteMutationPayload!
    applyNoteTags(input: ApplyNoteTagsInput!): NoteMutationPayload!
    removeNoteTag(noteId: String!, tagName: String!, provenance: String): NoteMutationPayload!
    addNoteComment(input: AddNoteCommentInput!): NoteMutationPayload!
    addNotebookComment(input: AddNotebookCommentInput!): NoteMutationPayload!
    setAppSetting(input: SetAppSettingInput!): AppSettingPayload!
    linkNotes(input: LinkNotesInput!): NoteMutationPayload!
    attachNoteFile(input: AttachNoteFileInput!): NoteMutationPayload!
    configureNoteAutoAction(input: ConfigureNoteAutoActionInput!): NoteMutationPayload!
    deleteNoteAutoAction(actionId: String!): ControlPlaneResult!
    saveNoteConversation(input: SaveNoteConversationInput!): NoteMutationPayload!
    sendAgentChatMessage(input: SendAgentChatMessageInput!): AgentChatMessagePayload!
    ensureTagMemoNotebook(tagId: String!): NoteMutationPayload!
    requestTagExtraction(input: RequestTagExtractionInput!): TagExtractionRequestPayload!
    requestNotebookTranslation(input: RequestNotebookTranslationInput!): NotebookTranslationRequestPayload!
    migrateNoteFileStorage(input: MigrateNoteFileStorageInput!): NoteFileMigrationPayload!
    migrateAllNoteFiles(input: MigrateAllNoteFilesInput!): NoteFileMigrationPayload!
    undoAction: UndoRedoPayload!
    redoAction: UndoRedoPayload!
  }
  """
}
