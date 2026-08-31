import Foundation

import AppCore

/// Validation, projection, and attribution helpers behind
/// `NoteGraphQLDocumentExecutor`, split out to keep the executor itself
/// focused on operation dispatch.

/// Resolves the audit-attribution identity (`assignedBy`/`author`) for a note
/// mutation.
///
/// On the authenticated HTTP note API (`authenticatedClientId` non-nil) the
/// identity is always the bearer-verified `client:<id>`; any explicit value in
/// the request is rejected so attribution cannot be forged. On the local
/// operator path (`authenticatedClientId` nil) the explicit value is honored.
func noteAPIAssignedBy(
  _ explicit: String?,
  field: String,
  request: GraphQLDocumentRequest
) throws -> String? {
  guard let clientId = request.authenticatedClientId else {
    return explicit
  }
  guard explicit == nil else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "\(field) cannot be set by an authenticated note API client"
    )
  }
  return "client:\(clientId)"
}

public func noteGraphQLRootFieldName(in query: String, operationName: String? = nil) -> String? {
  guard
    let fieldName = try? parseNoteGraphQLRootFields(
      in: query,
      operationName: operationName,
      variables: [:],
      parseArguments: false
    )?.first(where: { supportedNoteGraphQLFields.contains($0.fieldName) })?.fieldName
  else {
    return nil
  }
  return fieldName
}

public func noteGraphQLRootFieldNames(in query: String, operationName: String? = nil) throws -> [String] {
  try parseNoteGraphQLRootFields(
    in: query,
    operationName: operationName,
    variables: [:],
    parseArguments: false
  )?.map(\.fieldName) ?? []
}

public func noteGraphQLRequiresAuthentication(in query: String, operationName: String? = nil) -> Bool {
  do {
    return try noteGraphQLRootFieldNames(in: query, operationName: operationName)
      .contains { supportedNoteGraphQLFields.contains($0) }
  } catch {
    return true
  }
}

public func noteGraphQLOperationTypeName(in query: String, operationName: String? = nil) -> String {
  guard
    let operationType = try? parseNoteGraphQLRootFields(
      in: query,
      operationName: operationName,
      variables: [:],
      parseArguments: false
    )?.first?.operationType
  else {
    return "unknown"
  }
  switch operationType {
  case .query:
    return "query"
  case .mutation:
    return "mutation"
  }
}

let supportedNoteGraphQLFields: Set<String> = [
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
  "autoActions",
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
  "setAppSetting",
  "linkNotes",
  "attachNoteFile",
  "configureNoteAutoAction",
  "deleteNoteAutoAction",
  "saveNoteConversation",
  "sendAgentChatMessage",
  "requestTagExtraction",
  "requestNotebookTranslation",
  "noteConversations",
  "notebookConversations",
  "agentModels",
  "noteComments",
  "notebookComments",
  "tagDetail",
  "tagComments",
  "ensureTagMemoNotebook",
  "agenticSearch",
  "appSetting",
  "actionHistory",
  "undoState",
  "undoAction",
  "redoAction",
  "migrateNoteFileStorage",
  "migrateAllNoteFiles",
  "reclaimNoteFileStorage",
  "checkNoteStore",
  "optimizeNoteStore"
]

let noteGraphQLQueryFields: Set<String> = [
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
  "actionHistory",
  "undoState"
]

let noteGraphQLMutationFields = supportedNoteGraphQLFields.subtracting(noteGraphQLQueryFields)

func validateOperationType(_ operationType: GraphQLDocumentOperationType, fieldName: String) throws {
  switch operationType {
  case .query:
    guard noteGraphQLQueryFields.contains(fieldName) else {
      throw NoteGraphQLDocumentExecutorError.operationFieldMismatch(operation: "query", fieldName: fieldName)
    }
  case .mutation:
    guard noteGraphQLMutationFields.contains(fieldName) else {
      throw NoteGraphQLDocumentExecutorError.operationFieldMismatch(operation: "mutation", fieldName: fieldName)
    }
  }
}

func validateSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  rootFieldName: String
) throws {
  guard !selections.isEmpty else {
    return
  }
  let rootType = noteGraphQLRootSelectionTypes[rootFieldName] ?? "NoteMutationPayload"
  try validateSelections(selections, typeName: rootType, path: rootFieldName)
}

func validateSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String
) throws {
  guard let fields = noteGraphQLSelectionFields[typeName] else {
    guard selections.isEmpty else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path) does not support nested selections")
    }
    return
  }
  guard !selections.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path) requires nested selections")
  }
  for selection in selections {
    guard selection.fragmentTypeConditions.allSatisfy({ $0 == typeName }) else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "fragment type condition is incompatible with '\(typeName)' at \(path)"
      )
    }
    guard selection.arguments.isEmpty else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection(
        "\(path).\(selection.fieldName) does not accept arguments"
      )
    }
    if selection.fieldName == "__typename" {
      guard selection.selections.isEmpty else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path).__typename does not support nested selections")
      }
      continue
    }
    guard let childType = fields[selection.fieldName] else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("unsupported field '\(path).\(selection.fieldName)'")
    }
    if let childType {
      try validateSelections(selection.selections, typeName: childType, path: "\(path).\(selection.fieldName)")
    } else if !selection.selections.isEmpty {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path).\(selection.fieldName) does not support nested selections")
    }
  }
}

func projectGraphQLValue(
  _ value: JSONValue,
  selections: [ParsedNoteGraphQLSelectionField],
  typeName: String
) throws -> JSONValue {
  switch value {
  case let .array(values):
    return .array(try values.map { try projectGraphQLValue($0, selections: selections, typeName: typeName) })
  case let .object(object):
    guard let fields = noteGraphQLSelectionFields[typeName] else {
      return value
    }
    var projected: JSONObject = [:]
    for selection in selections {
      if selection.fieldName == "__typename" {
        guard projected[selection.responseKey] == nil else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(selection.responseKey)'")
        }
        projected[selection.responseKey] = .string(typeName)
        continue
      }
      guard let childType = fields[selection.fieldName] else {
        continue
      }
      guard projected[selection.responseKey] == nil else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(selection.responseKey)'")
      }
      let childValue = object[selection.fieldName] ?? .null
      if let childType {
        projected[selection.responseKey] = try projectGraphQLValue(
          childValue,
          selections: selection.selections,
          typeName: childType
        )
      } else {
        projected[selection.responseKey] = childValue
      }
    }
    return .object(projected)
  case .null:
    return .null
  case .bool, .integer, .number, .string:
    return value
  }
}

let noteGraphQLRootSelectionTypes: [String: String] = [
  "note": "NoteQueryPayload",
  "notebook": "NotebookQueryPayload",
  "notebooks": "NotebooksQueryPayload",
  "libraries": "NoteLibrariesQueryPayload",
  "notes": "NotesQueryPayload",
  "searchNotes": "NoteSearchQueryPayload",
  "noteGraphNeighbors": "NoteGraphNeighborsQueryPayload",
  "proposeNoteLinks": "NoteLinkProposalQueryPayload",
  "tags": "NoteTagsQueryPayload",
  "tagClasses": "NoteTagClassesQueryPayload",
  "noteFile": "NoteFileQueryPayload",
  "noteFiles": "NoteFilesQueryPayload",
  "autoActions": "NoteAutoActionsQueryPayload",
  "noteConversations": "AgentConversationsQueryPayload",
  "notebookConversations": "AgentConversationsQueryPayload",
  "agentModels": "AgentModelsPayload",
  "noteComments": "NoteCommentsQueryPayload",
  "notebookComments": "NoteCommentsQueryPayload",
  "tagDetail": "TagDetailQueryPayload",
  "tagComments": "TagCommentsQueryPayload",
  "agenticSearch": "AgenticSearchPayload",
  "appSetting": "AppSettingPayload",
  "setAppSetting": "AppSettingPayload",
  "actionHistory": "ActionHistoryPayload",
  "undoState": "UndoStatePayload",
  "undoAction": "UndoRedoPayload",
  "redoAction": "UndoRedoPayload",
  "sendAgentChatMessage": "AgentChatMessagePayload",
  "requestTagExtraction": "TagExtractionRequestPayload",
  "requestNotebookTranslation": "NotebookTranslationRequestPayload",
  "deleteNote": "ControlPlaneResult",
  "deleteNotebook": "ControlPlaneResult",
  "deleteNoteAutoAction": "ControlPlaneResult",
  "migrateNoteFileStorage": "NoteFileMigrationPayload",
  "migrateAllNoteFiles": "NoteFileMigrationPayload",
  "reclaimNoteFileStorage": "NoteFileReclamationPayload",
  "checkNoteStore": "NoteStoreCheckPayload",
  "optimizeNoteStore": "NoteStoreOptimizationPayload"
]

let noteGraphQLSelectionFields: [String: [String: String?]] = [
  "ControlPlaneResult": [
    "accepted": nil,
    "status": nil,
    "diagnostics": nil
  ],
  "NoteQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Note"),
  "NotebookQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Notebook"),
  "NotebooksQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Notebook"),
  "NoteLibrariesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteLibrary"),
  "NotesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Note"),
  "NoteSearchQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteSearchResult"),
  "NoteGraphNeighborsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteGraphNeighbor"),
  "NoteLinkProposalQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteLinkProposal"),
  "NoteTagsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteTag"),
  "NoteTagClassesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteTagClass"),
  "NoteFileQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteFile"),
  "NoteFilesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteFileAttachment"),
  "NoteAutoActionsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteAutoAction"),
  "AgentConversationsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "AgentConversation"),
  "AgentModelsPayload": [
    "result": "ControlPlaneResult",
    "models": "AgentModel",
    "discoveryAvailable": nil,
    "configuredModel": nil
  ],
  "AgentModel": [
    "modelId": nil,
    "displayName": nil,
    "description": nil
  ],
  "NoteCommentsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteComment"),
  "TagDetailQueryPayload": noteGraphQLQueryPayloadFields(valueType: "TagDetail"),
  "TagDetail": [
    "tag": "NoteTag",
    "tagClass": "NoteTagClass",
    "noteCount": nil,
    "notebookCount": nil,
    "memoNotebookId": nil
  ],
  "TagCommentsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "TagComment"),
  "TagComment": [
    "comment": "NoteComment",
    "noteTitle": nil,
    "notebookTitle": nil
  ],
  "AgentConversation": [
    "notebookId": nil,
    "title": nil,
    "updatedAt": nil,
    "turnCount": nil,
    "subjectNoteId": nil,
    "subjectNotebookId": nil
  ],
  "AgentChatMessagePayload": [
    "result": "ControlPlaneResult",
    "conversationNotebookId": nil,
    "turnNoteId": nil,
    "agentStatus": nil
  ],
  "AgenticSearchPayload": [
    "result": "ControlPlaneResult",
    "status": nil,
    "answerMarkdown": nil
  ],
  "AppSettingPayload": [
    "result": "ControlPlaneResult",
    "key": nil,
    "valueJSON": nil
  ],
  "ActionHistoryPayload": [
    "result": "ControlPlaneResult",
    "entries": "NoteActionLogEntry"
  ],
  "UndoStatePayload": [
    "result": "ControlPlaneResult",
    "undo": "NoteActionLogEntry",
    "redo": "NoteActionLogEntry"
  ],
  "UndoRedoPayload": [
    "result": "ControlPlaneResult",
    "status": nil,
    "applied": "NoteActionLogEntry",
    "target": "NoteActionLogEntry"
  ],
  "NoteActionLogEntry": [
    "seq": nil,
    "occurredAt": nil,
    "actorUserId": nil,
    "provenance": nil,
    "entityType": nil,
    "entityId": nil,
    "notebookId": nil,
    "action": nil,
    "title": nil,
    "undoable": nil,
    "undoOfSeq": nil,
    "undoneBySeq": nil
  ],
  "TagExtractionRequestPayload": [
    "result": "ControlPlaneResult",
    "status": nil
  ],
  "NotebookTranslationRequestPayload": [
    "result": "ControlPlaneResult",
    "translationNotebookId": nil,
    "status": nil
  ],
  "NoteMutationPayload": [
    "result": "ControlPlaneResult",
    "note": "Note",
    "notebook": "Notebook",
    "notes": "Note",
    "tag": "NoteTag",
    "tagClass": "NoteTagClass",
    "file": "NoteFile",
    "comment": "NoteComment",
    "link": "NoteLink",
    "autoAction": "NoteAutoAction"
  ],
  "NoteFileMigrationPayload": [
    "result": "ControlPlaneResult",
    "migrated": "NoteFile",
    "failures": "NoteFileMigrationFailure",
    "cleanupFailures": "NoteFileMigrationFailure"
  ],
  "NoteFileReclamationPayload": [
    "result": "ControlPlaneResult",
    "deletedFileIds": nil,
    "sweptPaths": nil
  ],
  "NoteStoreCheckPayload": [
    "result": "ControlPlaneResult",
    "schemaVersion": nil,
    "healthy": nil,
    "integrityMessages": nil,
    "foreignKeyViolations": nil,
    "searchIndexHealthy": nil,
    "notesMissingFromSearchIndex": nil,
    "orphanedSearchIndexRows": nil,
    "unreferencedFiles": nil,
    "searchIndexRepaired": nil
  ],
  "NoteStoreOptimizationPayload": [
    "result": "ControlPlaneResult",
    "vacuumed": nil,
    "bytesBefore": nil,
    "bytesAfter": nil,
    "freelistPagesBefore": nil,
    "freelistPagesAfter": nil
  ],
  "Note": [
    "noteId": nil,
    "notebookId": nil,
    "noteNumber": nil,
    "title": nil,
    "bodyMarkdown": nil,
    "readOnly": nil,
    "createdAt": nil,
    "updatedAt": nil,
    "metaJSON": nil,
    "tags": "NoteTagAssignment",
    "createdBy": nil,
    "updatedBy": nil
  ],
  "Notebook": [
    "notebookId": nil,
    "title": nil,
    "readOnly": nil,
    "createdAt": nil,
    "updatedAt": nil,
    "metaJSON": nil,
    "tags": "NoteTagAssignment",
    "firstNotePreview": nil,
    "noteCount": nil,
    "libraryId": nil,
    "ownerUserId": nil,
    "createdBy": nil,
    "updatedBy": nil
  ],
  "NoteLibrary": [
    "libraryId": nil,
    "name": nil,
    "title": nil,
    "authRequired": nil,
    "isDefault": nil,
    "createdAt": nil,
    "notebookCount": nil
  ],
  "NoteTagAssignment": [
    "tag": "NoteTag",
    "provenance": nil,
    "assignedBy": nil,
    "deletable": nil,
    "createdAt": nil
  ],
  "NoteTag": [
    "tagId": nil,
    "name": nil,
    "classId": nil,
    "parentTagId": nil,
    "isSystem": nil,
    "createdAt": nil
  ],
  "NoteTagClass": [
    "classId": nil,
    "label": nil,
    "description": nil,
    "isSystem": nil,
    "createdAt": nil
  ],
  "NoteFile": [
    "fileId": nil,
    "storageKind": nil,
    "localPath": nil,
    "s3Profile": nil,
    "s3Bucket": nil,
    "s3Key": nil,
    "mediaType": nil,
    "byteSize": nil,
    "sha256": nil,
    "originalFilename": nil,
    "createdAt": nil,
    "migratedAt": nil
  ],
  "NoteFileAttachment": [
    "noteId": nil,
    "file": "NoteFile",
    "role": nil,
    "position": nil
  ],
  "NoteComment": [
    "commentId": nil,
    "noteId": nil,
    "notebookId": nil,
    "bodyMarkdown": nil,
    "author": nil,
    "createdAt": nil
  ],
  "NoteLink": [
    "fromNoteId": nil,
    "toNoteId": nil,
    "linkKind": nil,
    "provenance": nil,
    "createdAt": nil
  ],
  "NoteSearchResult": [
    "note": "Note",
    "snippet": nil,
    "rank": nil,
    "matchedTags": "NoteTag",
    "isLinkedNeighbor": nil
  ],
  "NoteGraphNeighbor": [
    "seedNoteId": nil,
    "note": "Note",
    "edgeKind": nil,
    "weight": nil,
    "hopCount": nil,
    "pathNoteIds": nil
  ],
  "NoteLinkProposal": [
    "targetNote": "Note",
    "targetNoteId": nil,
    "linkKind": nil,
    "reason": nil,
    "source": nil
  ],
  "NoteAutoAction": [
    "actionId": nil,
    "trigger": nil,
    "workflowId": nil,
    "filterJSON": nil,
    "enabled": nil,
    "position": nil,
    "createdAt": nil
  ],
  "NoteFileMigrationFailure": [
    "fileId": nil,
    "message": nil
  ]
]

func noteGraphQLQueryPayloadFields(valueType: String) -> [String: String?] {
  [
    "result": "ControlPlaneResult",
    "value": valueType
  ]
}

func noteFileMigrationControlResult(_ result: NoteFileMigrationResult) -> GraphQLControlPlaneResult {
  guard !result.failures.isEmpty else {
    return GraphQLControlPlaneResult(accepted: true, status: "ok")
  }
  return GraphQLControlPlaneResult(
    accepted: false,
    status: result.migrated.isEmpty ? "failed" : "partial",
    // Redact per-file diagnostics with the same fixed message as the `failures`
    // list; `$0.message` is raw `String(describing: error)` and would otherwise
    // disclose paths, SQL, or S3 endpoints in a client-selectable field.
    diagnostics: result.failures.map { "\($0.fileId): \(noteFileMigrationFailureMessage)" }
  )
}

/// Fixed, redacted message reported for every note file migration failure in
/// the `failures` list so that raw storage errors (paths, SQL, S3 endpoints)
/// never reach a response body.
let noteFileMigrationFailureMessage = "note file migration failed"

func noteFileMigrationControlResult(
  for error: Error,
  hasMigratedFiles: Bool
) -> GraphQLControlPlaneResult {
  GraphQLControlPlaneResult(
    accepted: false,
    status: hasMigratedFiles ? "partial" : "failed",
    diagnostics: [graphQLNotePublicDiagnostic(for: error)]
  )
}
