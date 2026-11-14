import XCTest
@testable import AppGraphQL

final class NoteGraphQLSchemaInventoryTests: XCTestCase {
  func testPublishedNoteSchemaRootFieldsAreRoutableByExecutor() {
    let queryFields: Set<String> = [
      "note",
      "notebook",
      "notebooks",
      "libraries",
      "notes",
      "searchNotes",
      "noteGraphNeighbors",
      "proposeNoteLinks",
      "tags",
      "tagClasses",
      "noteFile",
      "noteFiles",
      "notebookFiles",
      "noteLinks",
      "longTermMemoryNotebook",
      "autoActions",
      "noteConversations",
      "notebookConversations",
      "noteComments",
      "notebookComments",
      "tagDetail",
      "tagComments",
      "agentModels",
      "agenticSearch",
      "appSetting",
      "userAgentCredential",
      "actionHistory",
      "undoState"
    ]
    let mutationFields: Set<String> = [
      "createNote",
      "createNotebook",
      "defineNoteTagClass",
      "defineNoteTag",
      "updateNote",
      "deleteNote",
      "deleteNotebook",
      "applyNotebookTags",
      "applyNotebookTagIds",
      "removeNotebookTag",
      "removeNotebookTagById",
      "setNotebookReadOnly",
      "setNoteReadOnly",
      "applyNoteTags",
      "removeNoteTag",
      "addNoteComment",
      "addNotebookComment",
      "openMemoNotebook",
      "setAppSetting",
      "setUserAgentCredential",
      "setUserAgentCredentialEnabled",
      "clearUserAgentCredential",
      "linkNotes",
      "attachNoteFile",
      "attachNotebookFile",
      "ingestNotebookPages",
      "appendLongTermMemory",
      "recallLongTermMemory",
      "linkLongTermMemoryAssociations",
      "configureNoteAutoAction",
      "deleteNoteAutoAction",
      "saveNoteConversation",
      "sendAgentChatMessage",
      "ensureTagMemoNotebook",
      "requestTagExtraction",
      "requestNotebookTranslation",
      "migrateNoteFileStorage",
      "migrateAllNoteFiles",
      "reclaimNoteFileStorage",
      "checkNoteStore",
      "optimizeNoteStore",
      "undoAction",
      "redoAction"
    ]

    XCTAssertEqual(supportedNoteGraphQLFields, queryFields.union(mutationFields))
    for field in queryFields {
      XCTAssertEqual(noteGraphQLRootFieldName(in: "query Test { \(field) { result { accepted } } }"), field)
    }
    for field in mutationFields {
      XCTAssertEqual(noteGraphQLRootFieldName(in: "mutation Test { \(field) { result { accepted } } }"), field)
    }
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteTags:"))
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteTagClasses:"))
    XCTAssertFalse(GraphQLContractProjector.schemaContract.contains("noteAutoActions:"))
  }
}
