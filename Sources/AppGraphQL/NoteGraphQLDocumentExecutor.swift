import Foundation

import AppCore

public struct GraphQLDocumentRequest: Equatable, Sendable {
  public var query: String
  public var variables: JSONObject
  public var operationName: String?
  public var environment: [String: String]
  public var authenticatedClientId: String?
  public var transportCredential: GraphQLTransportCredential?
  public var isLocallyTrusted: Bool
  public var localWorkingDirectory: String?
  var parsedRootFields: [ParsedNoteGraphQLRootField]?
  var domainPreflightComplete: Bool

  public init(
    query: String,
    variables: JSONObject = [:],
    operationName: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    authenticatedClientId: String? = nil,
    transportCredential: GraphQLTransportCredential? = nil,
    isLocallyTrusted: Bool = false,
    localWorkingDirectory: String? = nil
  ) {
    self.query = query
    self.variables = variables
    self.operationName = operationName
    self.environment = environment
    self.authenticatedClientId = authenticatedClientId
    self.transportCredential = transportCredential
    self.isLocallyTrusted = isLocallyTrusted
    self.localWorkingDirectory = localWorkingDirectory
    parsedRootFields = nil
    domainPreflightComplete = false
  }
}

public struct GraphQLTransportCredential: Equatable, Sendable {
  let value: String

  public init(_ value: String) {
    self.value = value
  }
}

public struct GraphQLDocumentExecutionResponse: Equatable, Sendable {
  public var handled: Bool
  public var status: Int
  public var body: JSONObject

  public init(handled: Bool, status: Int = 200, body: JSONObject = [:]) {
    self.handled = handled
    self.status = status
    self.body = body
  }

  public static let notHandled = GraphQLDocumentExecutionResponse(handled: false)
}

public protocol GraphQLDocumentExecuting: Sendable {
  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse
}

protocol GraphQLDocumentDomainPreflighting: Sendable {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedNoteGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse?
}

public struct NoteGraphQLDocumentExecutor: GraphQLDocumentExecuting, GraphQLDocumentDomainPreflighting {
  public static let defaultRawS3EnvironmentAllowlist: Set<String> = [
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN"
  ]

  public var service: GraphQLNoteGraphQLService
  public var s3HTTPClient: any S3HTTPClient
  public var s3Profiles: [S3StorageProfile]
  public var allowRawS3ProfileInput: Bool
  public var rawS3EnvironmentAllowlist: Set<String>

  public init(
    service: GraphQLNoteGraphQLService,
    s3HTTPClient: any S3HTTPClient = URLSessionS3HTTPClient(),
    s3Profiles: [S3StorageProfile] = [],
    allowRawS3ProfileInput: Bool = false,
    rawS3EnvironmentAllowlist: Set<String> = Self.defaultRawS3EnvironmentAllowlist
  ) {
    self.service = service
    self.s3HTTPClient = s3HTTPClient
    self.s3Profiles = s3Profiles
    self.allowRawS3ProfileInput = allowRawS3ProfileInput
    self.rawS3EnvironmentAllowlist = rawS3EnvironmentAllowlist
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let rootFields: [ParsedNoteGraphQLRootField]
    do {
      guard let parsed = try request.parsedRootFields ?? parseNoteGraphQLRootFields(
        in: request.query,
        operationName: request.operationName,
        variables: request.variables,
        parseArguments: true
      ), !parsed.isEmpty else {
        return .notHandled
      }
      rootFields = parsed
    } catch {
      // The document failed to parse. Routing only dispatches note documents to
      // this executor, so surface the explicit parse error rather than falling
      // through. Use the note root field as the response key when it can still be
      // identified by the directive-tolerant scan.
      let responseKey = noteGraphQLRootFieldName(in: request.query, operationName: request.operationName) ?? "noteGraphQL"
      return errorResponse(responseKeys: [responseKey], error: error)
    }
    let routedRootFields = rootFields.filter { supportedNoteGraphQLFields.contains($0.fieldName) }
    guard !routedRootFields.isEmpty else {
      return .notHandled
    }
    guard request.domainPreflightComplete || routedRootFields.count == rootFields.count else {
      return errorResponse(
        responseKeys: routedRootFields.map(\.responseKey),
        error: NoteGraphQLDocumentExecutorError.invalidSelection("mixed-domain document requires composite preflight")
      )
    }
    do {
      var data: JSONObject = [:]
      for rootField in routedRootFields {
        try validateOperationType(rootField.operationType, fieldName: rootField.fieldName)
        try validateSelections(rootField.selections, rootFieldName: rootField.fieldName)
        var routedRequest = request
        routedRequest.variables = rootField.arguments
        guard data[rootField.responseKey] == nil else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(rootField.responseKey)'")
        }
        let value = try await execute(fieldName: rootField.fieldName, request: routedRequest)
        let rootType = noteGraphQLRootSelectionTypes[rootField.fieldName] ?? "NoteMutationPayload"
        data[rootField.responseKey] = try projectGraphQLValue(value, selections: rootField.selections, typeName: rootType)
      }
      return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
    } catch {
      return errorResponse(responseKeys: routedRootFields.map(\.responseKey), error: error)
    }
  }

  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedNoteGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    do {
      guard !rootFields.isEmpty,
            rootFields.allSatisfy({ supportedNoteGraphQLFields.contains($0.fieldName) }) else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("unsupported mixed-domain root field")
      }
      var responseKeys = Set<String>()
      for rootField in rootFields {
        try validateOperationType(rootField.operationType, fieldName: rootField.fieldName)
        try validateSelections(rootField.selections, rootFieldName: rootField.fieldName)
        guard responseKeys.insert(rootField.responseKey).inserted else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection(
            "duplicate response key '\(rootField.responseKey)'"
          )
        }
      }
      return nil
    } catch {
      return errorResponse(responseKeys: rootFields.map(\.responseKey), error: error)
    }
  }

  private func errorResponse(responseKeys: [String], error: Error) -> GraphQLDocumentExecutionResponse {
    var data: JSONObject = [:]
    for responseKey in responseKeys {
      data[responseKey] = .null
    }
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: [
        "data": .object(data),
        "errors": .array([.object(["message": .string(graphQLNotePublicDiagnostic(for: error))])])
      ]
    )
  }

  private func execute(fieldName: String, request: GraphQLDocumentRequest) async throws -> JSONValue {
    let variables = request.variables
    switch fieldName {
    case "note":
      return try await encodedJSONValue(service.note(noteId: requiredString("noteId", variables: variables)))
    case "notebook":
      return try await encodedJSONValue(service.notebook(notebookId: requiredString("notebookId", variables: variables)))
    case "notebooks":
      return try await encodedJSONValue(service.notebooks(
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: validatedOffset(try optionalInt("offset", variables: variables)),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? [],
        tagFilterGroups: try optionalStringArrayArray("tagFilterGroups", variables: variables) ?? [],
        tagFilterIdGroups: try optionalStringArrayArray("tagFilterIdGroups", variables: variables) ?? [],
        sort: try optionalString("sort", variables: variables),
        createdAfter: try optionalString("createdAfter", variables: variables),
        createdBefore: try optionalString("createdBefore", variables: variables)
      ))
    case "notes":
      return try await encodedJSONValue(service.notes(
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: validatedOffset(try optionalInt("offset", variables: variables)),
        notebookId: try optionalString("notebookId", variables: variables),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? []
      ))
    case "searchNotes":
      return try await encodedJSONValue(service.searchNotes(
        query: requiredString("query", variables: variables),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? [],
        classFilter: try optionalStringArray("classFilter", variables: variables) ?? [],
        notebookId: try optionalString("notebookId", variables: variables),
        sort: try optionalString("sort", variables: variables),
        createdAfter: try optionalString("createdAfter", variables: variables),
        createdBefore: try optionalString("createdBefore", variables: variables),
        includeLinked: try optionalBool("includeLinked", variables: variables) ?? false,
        depth: try optionalInt("depth", variables: variables) ?? 1,
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 20),
        offset: validatedOffset(try optionalInt("offset", variables: variables))
      ))
    case "noteGraphNeighbors":
      return try await encodedJSONValue(service.noteGraphNeighbors(
        noteIds: try optionalStringArray("noteIds", variables: variables) ?? [],
        depth: try optionalInt("depth", variables: variables) ?? NoteGraphPolicy.defaultMaxDepth,
        limit: validatedGraphLimit(
          try optionalInt("limit", variables: variables),
          defaultValue: NoteGraphPolicy.defaultLimit
        )
      ))
    case "proposeNoteLinks":
      return try await encodedJSONValue(service.proposeNoteLinks(
        noteId: requiredString("noteId", variables: variables),
        limit: validatedGraphLimit(try optionalInt("limit", variables: variables), defaultValue: 8)
      ))
    case "tags":
      return try await encodedJSONValue(service.tags())
    case "tagClasses":
      return try await encodedJSONValue(service.tagClasses())
    case "noteFile":
      return try await encodedJSONValue(service.noteFile(fileId: requiredString("fileId", variables: variables)))
    case "noteFiles":
      return try await encodedJSONValue(service.noteFiles(noteId: requiredString("noteId", variables: variables)))
    case "autoActions":
      return try await encodedJSONValue(service.autoActions())
    case "noteConversations":
      return try await encodedJSONValue(service.noteConversations(
        noteId: requiredString("noteId", variables: variables),
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50)
      ))
    case "notebookConversations":
      return try await encodedJSONValue(service.notebookConversations(
        notebookId: requiredString("notebookId", variables: variables),
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50)
      ))
    case "agentModels":
      return try await encodedJSONValue(service.agentModels())
    case "noteComments":
      return try await encodedJSONValue(service.noteComments(
        noteId: requiredString("noteId", variables: variables)
      ))
    case "notebookComments":
      return try await encodedJSONValue(service.notebookComments(
        notebookId: requiredString("notebookId", variables: variables)
      ))
    case "tagDetail":
      return try await encodedJSONValue(service.tagDetail(
        tagId: requiredString("tagId", variables: variables)
      ))
    case "tagComments":
      return try await encodedJSONValue(service.tagComments(
        tagId: requiredString("tagId", variables: variables),
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: validatedOffset(try optionalInt("offset", variables: variables))
      ))
    case "agenticSearch":
      return try await encodedJSONValue(service.agenticSearch(
        query: requiredString("query", variables: variables),
        notebookId: try optionalString("notebookId", variables: variables),
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 20)
      ))
    case "appSetting":
      return try await encodedJSONValue(service.appSetting(
        key: requiredString("key", variables: variables)
      ))
    case "setNotebookReadOnly":
      return try await encodedJSONValue(service.setNotebookReadOnly(
        notebookId: requiredString("notebookId", variables: variables),
        readOnly: requiredBool("readOnly", variables: variables)
      ))
    default:
      return try await executeMutation(fieldName: fieldName, request: request)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func executeMutation(fieldName: String, request: GraphQLDocumentRequest) async throws -> JSONValue {
    let variables = request.variables
    switch fieldName {
    case "createNote":
      var input: GraphQLCreateNoteInput = try requiredInput("input", variables: variables)
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
      return try await encodedJSONValue(service.createNote(input))
    case "createNotebook":
      return try await encodedJSONValue(service.createNotebook(requiredInput("input", variables: variables)))
    case "defineNoteTagClass":
      return try await encodedJSONValue(service.defineTagClass(requiredInput("input", variables: variables)))
    case "defineNoteTag":
      return try await encodedJSONValue(service.defineTag(requiredInput("input", variables: variables)))
    case "updateNote":
      let input: GraphQLUpdateNoteInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.updateNote(
        noteId: input.noteId,
        bodyMarkdown: input.bodyMarkdown,
        originatingActionId: input.originatingActionId
      ))
    case "deleteNote":
      return try await encodedJSONValue(service.deleteNote(noteId: requiredString("noteId", variables: variables)))
    case "deleteNotebook":
      return try await encodedJSONValue(service.deleteNotebook(notebookId: requiredString("notebookId", variables: variables)))
    case "applyNotebookTags":
      var input: GraphQLApplyNotebookTagsInput = try requiredInput("input", variables: variables)
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
      return try await encodedJSONValue(service.applyNotebookTags(input))
    case "applyNotebookTagIds":
      var input: GraphQLApplyNotebookTagIdsInput = try requiredInput("input", variables: variables)
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
      return try await encodedJSONValue(service.applyNotebookTagIds(input))
    case "removeNotebookTag":
      return try await encodedJSONValue(service.removeNotebookTag(
        notebookId: requiredString("notebookId", variables: variables),
        tagName: requiredString("tagName", variables: variables),
        provenance: try optionalString("provenance", variables: variables) ?? "human"
      ))
    case "removeNotebookTagById":
      return try await encodedJSONValue(service.removeNotebookTagById(
        notebookId: requiredString("notebookId", variables: variables),
        tagId: requiredString("tagId", variables: variables),
        provenance: try optionalString("provenance", variables: variables) ?? "human"
      ))
    case "setNotebookReadOnly":
      return try await encodedJSONValue(service.setNotebookReadOnly(
        notebookId: requiredString("notebookId", variables: variables),
        readOnly: requiredBool("readOnly", variables: variables)
      ))
    case "setNoteReadOnly":
      return try await encodedJSONValue(service.setReadOnly(
        noteId: requiredString("noteId", variables: variables),
        readOnly: requiredBool("readOnly", variables: variables)
      ))
    case "applyNoteTags":
      let input: GraphQLApplyNoteTagsInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.applyTags(
        noteId: input.noteId,
        tags: input.tags,
        provenance: input.provenance ?? "ai",
        assignedBy: try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
      ))
    case "removeNoteTag":
      return try await encodedJSONValue(service.removeTag(
        noteId: requiredString("noteId", variables: variables),
        tagName: requiredString("tagName", variables: variables),
        provenance: try optionalString("provenance", variables: variables) ?? "human"
      ))
    case "addNoteComment":
      let input: GraphQLAddNoteCommentInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.addComment(
        noteId: input.noteId,
        bodyMarkdown: input.bodyMarkdown,
        author: try noteAPIAssignedBy(input.author, field: "author", request: request) ?? "user"
      ))
    case "addNotebookComment":
      let input: GraphQLAddNotebookCommentInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.addNotebookComment(
        notebookId: input.notebookId,
        bodyMarkdown: input.bodyMarkdown,
        author: try noteAPIAssignedBy(input.author, field: "author", request: request) ?? "user"
      ))
    case "setAppSetting":
      let input: GraphQLSetAppSettingInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.setAppSetting(
        key: input.key,
        valueJSON: input.valueJSON
      ))
    case "linkNotes":
      let input: GraphQLLinkNotesInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.linkNotes(
        from: input.fromNoteId,
        to: input.toNoteId,
        linkKind: input.linkKind ?? "related",
        provenance: input.provenance ?? "human"
      ))
    case "attachNoteFile":
      let input: GraphQLAttachNoteFileInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.attachFile(
        noteId: input.noteId,
        contentBase64: input.contentBase64,
        role: input.role ?? "related",
        mediaType: input.mediaType,
        originalFilename: input.originalFilename,
        position: input.position ?? 0
      ))
    case "configureNoteAutoAction":
      let input: GraphQLConfigureNoteAutoActionInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.configureAutoAction(
        actionId: input.actionId,
        trigger: input.trigger,
        workflowId: input.workflowId,
        filterJSON: input.filterJSON,
        enabled: input.enabled ?? true,
        position: input.position ?? 0
      ))
    case "deleteNoteAutoAction":
      return try await encodedJSONValue(service.deleteAutoAction(actionId: requiredString("actionId", variables: variables)))
    case "sendAgentChatMessage":
      let input: GraphQLSendAgentChatMessageInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.sendAgentChatMessage(input))
    case "ensureTagMemoNotebook":
      return try await encodedJSONValue(service.ensureTagMemoNotebook(
        tagId: requiredString("tagId", variables: variables)
      ))
    case "requestTagExtraction":
      let input: GraphQLRequestTagExtractionInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.requestTagExtraction(input))
    case "requestNotebookTranslation":
      let input: GraphQLRequestNotebookTranslationInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.requestNotebookTranslation(input))
    case "saveNoteConversation":
      let input: GraphQLSaveNoteConversationInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.saveConversation(
        title: input.title,
        transcript: input.transcript.map(\.noteTurn),
        assignedBy: try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request),
        originatingActionId: input.originatingActionId
      ))
    case "migrateNoteFileStorage":
      let input: GraphQLMigrateNoteFileStorageInput = try requiredInput("input", variables: variables)
      do {
        let migrated = try service.service.migrateFileStorageOutcome(
          fileId: input.fileId,
          to: try input.storageProfile(
            allowedProfiles: s3Profiles,
            environment: request.environment,
            allowRawInput: allowRawS3ProfileInput,
            rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
          ),
          httpClient: s3HTTPClient,
          verifyRemoteRead: false
        )
        return try encodedJSONValue(GraphQLNoteFileMigrationResult(
          result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
          migrated: [GraphQLNoteFileDTO(file: migrated.record)],
          cleanupFailures: migrated.cleanupFailure.map {
            [GraphQLNoteFileMigrationFailureDTO(
              NoteFileMigrationFailure(fileId: $0.fileId, message: noteFileMigrationFailureMessage)
            )]
          } ?? []
        ))
      } catch {
        return try encodedJSONValue(GraphQLNoteFileMigrationResult(
          result: noteFileMigrationControlResult(for: error, hasMigratedFiles: false),
          failures: [
            GraphQLNoteFileMigrationFailureDTO(
              NoteFileMigrationFailure(fileId: input.fileId, message: graphQLNotePublicDiagnostic(for: error))
            )
          ]
        ))
      }
    case "migrateAllNoteFiles":
      let input: GraphQLMigrateAllNoteFilesInput = try requiredInput("input", variables: variables)
      let migrated = try service.service.migrateAllLocalFiles(
        to: try input.storageProfile(
          allowedProfiles: s3Profiles,
          environment: request.environment,
          allowRawInput: allowRawS3ProfileInput,
          rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
        ),
        httpClient: s3HTTPClient
      )
      return try encodedJSONValue(GraphQLNoteFileMigrationResult(
        result: noteFileMigrationControlResult(migrated),
        migrated: migrated.migrated.map(GraphQLNoteFileDTO.init),
        failures: migrated.failures.map { failure in
          GraphQLNoteFileMigrationFailureDTO(
            NoteFileMigrationFailure(fileId: failure.fileId, message: noteFileMigrationFailureMessage)
          )
        },
        cleanupFailures: migrated.cleanupFailures.map { failure in
          GraphQLNoteFileMigrationFailureDTO(
            NoteFileMigrationFailure(fileId: failure.fileId, message: noteFileMigrationFailureMessage)
          )
        }
      ))
    case "reclaimNoteFileStorage":
      let input: GraphQLReclaimNoteFileStorageInput = try requiredInput("input", variables: variables)
      if let graceHours = input.graceHours, graceHours < 0 {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("graceHours must not be negative")
      }
      let profile = try input.optionalStorageProfile(
        allowedProfiles: s3Profiles,
        environment: request.environment,
        allowRawInput: allowRawS3ProfileInput,
        rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
      )
      let reclaimed = try service.service.reclaimUnreferencedFiles(
        olderThan: TimeInterval(input.graceHours ?? 24) * 60 * 60,
        s3Profiles: profile.map { [$0] } ?? [],
        httpClient: s3HTTPClient
      )
      return try encodedJSONValue(GraphQLNoteFileReclamationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        deletedFileIds: reclaimed.deletedFileIds,
        sweptPaths: reclaimed.sweptPaths
      ))
    default:
      return .null
    }
  }
}
