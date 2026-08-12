import Foundation

import AppCore

// Mirrors riela's InlineWorkflowAddonAttachmentProjector.maxAttachmentBytes;
// kaiba carries the bound directly since it has no workflow addon layer.
private let graphQLNoteMaxInlineFileBytes = 8 * 1024 * 1024

public struct GraphQLNoteQueryResult<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: Value?

  public init(result: GraphQLControlPlaneResult, value: Value? = nil) {
    self.result = result
    self.value = value
  }
}

public struct GraphQLNoteGraphQLService: Sendable {
  public var service: NoteService
  /// When set, `agenticSearch` runs synchronously against this agent runtime;
  /// nil reports `agent-unavailable` (mirrors every other AI surface).
  public var agentInvoker: (any AgentInvoking)?
  public var agentProvider: String?
  public var agentModel: String?
  /// Server-only model discovery; its result never exposes credentials or paths.
  public var agentModelCatalog: (@Sendable () async throws -> AgentGatewayModelCatalogResult)?

  public init(
    service: NoteService,
    agentInvoker: (any AgentInvoking)? = nil,
    agentProvider: String? = nil,
    agentModel: String? = nil,
    agentModelCatalog: (@Sendable () async throws -> AgentGatewayModelCatalogResult)? = nil
  ) {
    self.service = service
    self.agentInvoker = agentInvoker
    self.agentProvider = agentProvider
    self.agentModel = agentModel
    self.agentModelCatalog = agentModelCatalog
  }

  public func note(noteId: String) async -> GraphQLNoteQueryResult<GraphQLNoteDTO> {
    noteResult {
      GraphQLNoteDTO(note: try service.getNote(noteId))
    }
  }

  public func notebook(notebookId: String) async -> GraphQLNoteQueryResult<GraphQLNotebookDTO> {
    noteResult {
      GraphQLNotebookDTO(notebook: try service.getNotebook(notebookId))
    }
  }

  public func notebooks(
    limit: Int = 50,
    offset: Int = 0,
    tagFilter: [String] = [],
    tagFilterGroups: [[String]] = [],
    tagFilterIdGroups: [[String]] = [],
    sort: String? = nil,
    createdAfter: String? = nil,
    createdBefore: String? = nil
  ) async -> GraphQLNoteQueryResult<[GraphQLNotebookDTO]> {
    noteResult {
      try service.listNotebooks(
        limit: limit,
        offset: offset,
        tagFilter: tagFilter,
        tagFilterGroups: tagFilterGroups,
        tagFilterIdGroups: tagFilterIdGroups,
        sort: try graphQLNoteListSort(sort),
        createdAfter: createdAfter,
        createdBefore: createdBefore
      ).map(GraphQLNotebookDTO.init)
    }
  }

  public func notes(
    limit: Int = 50,
    offset: Int = 0,
    notebookId: String? = nil,
    tagFilter: [String] = []
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteDTO]> {
    noteResult {
      try service.listNotes(
        limit: limit,
        offset: offset,
        notebookId: notebookId,
        tagFilter: tagFilter
      ).map(GraphQLNoteDTO.init)
    }
  }

  public func searchNotes(
    query: String,
    tagFilter: [String] = [],
    classFilter: [String] = [],
    notebookId: String? = nil,
    sort: String? = nil,
    createdAfter: String? = nil,
    createdBefore: String? = nil,
    includeLinked: Bool = false,
    depth: Int = 1,
    limit: Int = 20,
    offset: Int = 0
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteSearchResultDTO]> {
    noteResult {
      try service.searchNotes(
        query: query,
        tagFilter: tagFilter,
        classFilter: classFilter,
        notebookId: notebookId,
        sort: try graphQLNoteListSort(sort),
        createdAfter: createdAfter,
        createdBefore: createdBefore,
        includeLinked: includeLinked,
        depth: depth,
        limit: limit,
        offset: offset
      ).map(GraphQLNoteSearchResultDTO.init)
    }
  }

  public func noteGraphNeighbors(
    noteIds: [String],
    depth: Int = NoteGraphPolicy.defaultMaxDepth,
    limit: Int = NoteGraphPolicy.defaultLimit
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteGraphNeighborDTO]> {
    noteResult {
      try service.graphNeighbors(noteIds: noteIds, maxDepth: depth, limit: limit)
        .map(GraphQLNoteGraphNeighborDTO.init)
    }
  }

  public func proposeNoteLinks(
    noteId: String,
    limit: Int = 8
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteLinkProposalDTO]> {
    noteResult {
      try service.proposeLinks(noteId: noteId, limit: limit).map(GraphQLNoteLinkProposalDTO.init)
    }
  }

  public func tags() async -> GraphQLNoteQueryResult<[GraphQLNoteTagDTO]> {
    noteResult {
      try service.listTags().map(GraphQLNoteTagDTO.init)
    }
  }

  public func tagClasses() async -> GraphQLNoteQueryResult<[GraphQLNoteTagClassDTO]> {
    noteResult {
      try service.listTagClasses().map(GraphQLNoteTagClassDTO.init)
    }
  }

  public func noteFile(fileId: String) async -> GraphQLNoteQueryResult<GraphQLNoteFileDTO> {
    noteResult {
      GraphQLNoteFileDTO(file: try service.getFileRecord(fileId: fileId))
    }
  }

  /// The note's attachments in store order (position, then created-at, then id).
  public func noteFiles(noteId: String) async -> GraphQLNoteQueryResult<[GraphQLNoteFileAttachmentDTO]> {
    noteResult {
      try service.listFiles(noteId: noteId).map(GraphQLNoteFileAttachmentDTO.init)
    }
  }

  public func autoActions() async -> GraphQLNoteQueryResult<[GraphQLNoteAutoActionDTO]> {
    noteResult {
      try service.listAutoActions().map(GraphQLNoteAutoActionDTO.init)
    }
  }

  public func createNote(_ input: GraphQLCreateNoteInput) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.createNote(
        notebookId: input.notebookId,
        notebookTitle: input.notebookTitle,
        title: input.title,
        bodyMarkdown: input.bodyMarkdown,
        readOnly: input.readOnly,
        tags: input.tags.map(\.noteInput),
        provenance: try graphQLNoteProvenance(input.provenance),
        assignedBy: input.assignedBy,
        metaJSON: input.metaJSON,
        originatingActionId: input.originatingActionId
      )
      return .init(result: .ok, note: GraphQLNoteDTO(note: note))
    }
  }

  public func createNotebook(_ input: GraphQLCreateNotebookInput) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.createNotebook(
        title: input.title,
        kindTagName: input.kindTagName,
        folderPath: input.folderPath ?? [],
        metaJSON: input.metaJSON,
        originatingActionId: input.originatingActionId
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func defineTagClass(_ input: GraphQLDefineNoteTagClassInput) async -> GraphQLNoteMutationResult {
    noteMutation {
      let tagClass = try service.defineTagClass(
        classId: input.classId,
        label: input.label,
        description: input.description
      )
      return .init(result: .ok, tagClass: GraphQLNoteTagClassDTO(tagClass: tagClass))
    }
  }

  public func defineTag(_ input: GraphQLDefineNoteTagInput) async -> GraphQLNoteMutationResult {
    noteMutation {
      let tag = try service.defineTag(
        name: input.name,
        classId: input.classId,
        parentTagId: input.parentTagId,
        createOnly: input.createOnly
      )
      return .init(result: .ok, tag: GraphQLNoteTagDTO(tag: tag))
    }
  }

  public func updateNote(noteId: String, bodyMarkdown: String, originatingActionId: String? = nil) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.updateNoteBody(
        noteId: noteId,
        bodyMarkdown: bodyMarkdown,
        originatingActionId: originatingActionId
      )
      return .init(result: .ok, note: GraphQLNoteDTO(note: note))
    }
  }

  public func deleteNote(noteId: String) async -> GraphQLControlPlaneResult {
    noteControlResult {
      try service.deleteNote(noteId: noteId)
    }
  }

  public func deleteNotebook(notebookId: String) async -> GraphQLControlPlaneResult {
    noteControlResult {
      try service.deleteNotebook(notebookId: notebookId)
    }
  }

  public func applyNotebookTags(
    _ input: GraphQLApplyNotebookTagsInput
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.applyNotebookTags(
        notebookId: input.notebookId,
        tags: input.tags,
        provenance: try graphQLNoteProvenance(input.provenance ?? NoteProvenance.ai.rawValue),
        assignedBy: input.assignedBy
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func applyNotebookTagIds(
    _ input: GraphQLApplyNotebookTagIdsInput
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.applyNotebookTagIds(
        notebookId: input.notebookId,
        tagIds: input.tagIds,
        provenance: try graphQLNoteProvenance(input.provenance ?? NoteProvenance.ai.rawValue),
        assignedBy: input.assignedBy
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func removeNotebookTag(
    notebookId: String,
    tagName: String,
    provenance: String = NoteProvenance.human.rawValue
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.removeNotebookTag(
        notebookId: notebookId,
        tagName: tagName,
        removedBy: try graphQLNoteProvenance(provenance)
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func removeNotebookTagById(
    notebookId: String,
    tagId: String,
    provenance: String = NoteProvenance.human.rawValue
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.removeNotebookTagById(
        notebookId: notebookId,
        tagId: tagId,
        removedBy: try graphQLNoteProvenance(provenance)
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func setNotebookProgress(
    notebookId: String,
    progress: String,
    expectedProgress: String? = nil
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.setNotebookProgress(
        notebookId: notebookId,
        progress: progress,
        expectedProgress: expectedProgress
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func setNotebookReadOnly(
    notebookId: String,
    readOnly: Bool
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let notebook = try service.setNotebookReadOnly(
        notebookId: notebookId,
        readOnly: readOnly
      )
      return .init(result: .ok, notebook: GraphQLNotebookDTO(notebook: notebook))
    }
  }

  public func kanbanStatusSets() async -> GraphQLNoteQueryResult<[GraphQLKanbanStatusSetDTO]> {
    noteResult {
      try service.listKanbanStatusSets().map(GraphQLKanbanStatusSetDTO.init)
    }
  }

  public func effectiveKanbanStatuses(tagName: String?) async -> GraphQLNoteQueryResult<GraphQLKanbanStatusSetDTO> {
    noteResult {
      GraphQLKanbanStatusSetDTO(set: try service.effectiveKanbanStatuses(tagName: tagName))
    }
  }

  public func effectiveKanbanStatusesByTagId(
    tagId: String
  ) async -> GraphQLNoteQueryResult<GraphQLKanbanStatusSetDTO> {
    noteResult {
      GraphQLKanbanStatusSetDTO(set: try service.effectiveKanbanStatusesByTagId(tagId: tagId))
    }
  }

  public func createKanbanStatusSet(
    name: String,
    statuses: [GraphQLKanbanStatusInput]
  ) async -> GraphQLNoteQueryResult<GraphQLKanbanStatusSetDTO> {
    noteResult {
      GraphQLKanbanStatusSetDTO(
        set: try service.createKanbanStatusSet(
          name: name,
          statuses: try statuses.map { try $0.upsert() }
        )
      )
    }
  }

  public func updateKanbanStatusSet(
    setId: String,
    statuses: [GraphQLKanbanStatusInput],
    reassignments: [GraphQLKanbanStatusReassignmentInput] = []
  ) async -> GraphQLNoteQueryResult<GraphQLKanbanStatusSetDTO> {
    noteResult {
      GraphQLKanbanStatusSetDTO(
        set: try service.updateKanbanStatusSet(
          setId: setId,
          statuses: try statuses.map { try $0.upsert() },
          removedReassignTo: Dictionary(
            reassignments.map { ($0.removedName, $0.reassignTo) },
            uniquingKeysWith: { _, last in last }
          )
        )
      )
    }
  }

  public func deleteKanbanStatusSet(setId: String) async -> GraphQLControlPlaneResult {
    noteControlResult {
      try service.deleteKanbanStatusSet(setId: setId)
    }
  }

  public func assignKanbanStatusSet(tagName: String, setId: String?) async -> GraphQLNoteMutationResult {
    noteMutation {
      let tag = try service.assignKanbanStatusSet(tagName: tagName, setId: setId)
      return .init(result: .ok, tag: GraphQLNoteTagDTO(tag: tag))
    }
  }

  public func assignKanbanStatusSetByTagId(
    tagId: String,
    setId: String?
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let tag = try service.assignKanbanStatusSetByTagId(tagId: tagId, setId: setId)
      return .init(result: .ok, tag: GraphQLNoteTagDTO(tag: tag))
    }
  }

  public func setReadOnly(noteId: String, readOnly: Bool) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.setReadOnly(noteId: noteId, readOnly: readOnly)
      return .init(result: .ok, note: GraphQLNoteDTO(note: note))
    }
  }

  public func applyTags(
    noteId: String,
    tags: [GraphQLNoteTagInput],
    provenance: String = NoteProvenance.ai.rawValue,
    assignedBy: String? = nil
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.applyTags(
        noteId: noteId,
        tags: tags.map(\.noteInput),
        provenance: try graphQLNoteProvenance(provenance),
        assignedBy: assignedBy
      )
      return .init(result: .ok, note: GraphQLNoteDTO(note: note))
    }
  }

  public func removeTag(
    noteId: String,
    tagName: String,
    provenance: String = NoteProvenance.human.rawValue
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let note = try service.removeTag(
        noteId: noteId,
        tagName: tagName,
        removedBy: try graphQLNoteProvenance(provenance)
      )
      return .init(result: .ok, note: GraphQLNoteDTO(note: note))
    }
  }

  public func addComment(noteId: String, bodyMarkdown: String, author: String = "user") async -> GraphQLNoteMutationResult {
    noteMutation {
      let comment = try service.addComment(noteId: noteId, bodyMarkdown: bodyMarkdown, author: author)
      return .init(result: .ok, comment: GraphQLNoteCommentDTO(comment: comment))
    }
  }

  public func addNotebookComment(
    notebookId: String,
    bodyMarkdown: String,
    author: String = "user"
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let comment = try service.addNotebookComment(
        notebookId: notebookId,
        bodyMarkdown: bodyMarkdown,
        author: author
      )
      return .init(result: .ok, comment: GraphQLNoteCommentDTO(comment: comment))
    }
  }

  public func linkNotes(
    from fromNoteId: String,
    to toNoteId: String,
    linkKind: String = "related",
    provenance: String = NoteProvenance.human.rawValue
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let link = try service.linkNotes(
        from: fromNoteId,
        to: toNoteId,
        linkKind: linkKind,
        provenance: try graphQLNoteProvenance(provenance)
      )
      return .init(result: .ok, link: GraphQLNoteLinkDTO(link: link))
    }
  }

  public func attachFile(
    noteId: String,
    contentBase64: String,
    role: String = NoteFileRole.related.rawValue,
    mediaType: String,
    originalFilename: String? = nil,
    position: Int = 0
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      guard estimatedBase64DecodedByteCount(contentBase64) <= graphQLNoteMaxInlineFileBytes else {
        throw GraphQLNoteServiceError.invalidRequest(
          "contentBase64 decoded payload exceeds \(graphQLNoteMaxInlineFileBytes) bytes"
        )
      }
      guard let data = Data(base64Encoded: contentBase64) else {
        throw GraphQLNoteServiceError.invalidRequest("contentBase64 is not valid base64")
      }
      guard data.count <= graphQLNoteMaxInlineFileBytes else {
        throw GraphQLNoteServiceError.invalidRequest(
          "contentBase64 decoded payload exceeds \(graphQLNoteMaxInlineFileBytes) bytes"
        )
      }
      guard let noteFileRole = NoteFileRole(rawValue: role) else {
        throw GraphQLNoteServiceError.invalidRequest("unsupported note file role: \(role)")
      }
      let attachment = try service.attachFile(
        noteId: noteId,
        data: data,
        role: noteFileRole,
        mediaType: mediaType,
        originalFilename: originalFilename,
        position: position
      )
      return .init(result: .ok, file: GraphQLNoteFileDTO(file: attachment.file))
    }
  }

  public func configureAutoAction(
    actionId: String,
    trigger: String,
    workflowId: String,
    filterJSON: String? = nil,
    enabled: Bool = true,
    position: Int = 0
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      guard let trigger = NoteAutoActionTrigger(rawValue: trigger) else {
        throw GraphQLNoteServiceError.invalidRequest("unsupported auto-action trigger: \(trigger)")
      }
      let action = try service.configureAutoAction(
        actionId: actionId,
        trigger: trigger,
        workflowId: workflowId,
        filterJSON: filterJSON,
        enabled: enabled,
        position: position
      )
      return .init(result: .ok, autoAction: GraphQLNoteAutoActionDTO(action: action))
    }
  }

  public func deleteAutoAction(actionId: String) async -> GraphQLControlPlaneResult {
    noteControlResult {
      try service.deleteAutoAction(actionId: actionId)
    }
  }

  public func saveConversation(
    title: String,
    transcript: [NoteConversationTurn],
    assignedBy: String? = nil,
    originatingActionId: String? = nil
  ) async -> GraphQLNoteMutationResult {
    noteMutation {
      let saved = try service.saveConversation(
        title: title,
        transcript: transcript,
        assignedBy: assignedBy,
        originatingActionId: originatingActionId
      )
      return .init(
        result: .ok,
        notebook: GraphQLNotebookDTO(notebook: saved.notebook),
        notes: saved.notes.map(GraphQLNoteDTO.init)
      )
    }
  }

  public func noteConversations(
    noteId: String,
    limit: Int = 50
  ) async -> GraphQLNoteQueryResult<[GraphQLAgentConversationDTO]> {
    noteResult {
      try service.listAgentConversations(subjectNoteId: noteId, limit: limit)
        .map(GraphQLAgentConversationDTO.init)
    }
  }

  /// Conversations whose subject is the whole notebook (no note selected).
  public func notebookConversations(
    notebookId: String,
    limit: Int = 50
  ) async -> GraphQLNoteQueryResult<[GraphQLAgentConversationDTO]> {
    noteResult {
      try service.listAgentConversations(subjectNotebookId: notebookId, limit: limit)
        .map(GraphQLAgentConversationDTO.init)
    }
  }

  public func noteComments(
    noteId: String
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteCommentDTO]> {
    noteResult {
      try service.listComments(noteId: noteId).map(GraphQLNoteCommentDTO.init)
    }
  }

  /// Agentic search: the configured agent answers a search question over the
  /// store, with the kaiba CLI usage in its prompt and a grep pass as
  /// grounding context. `status` is "ok", "agent-unavailable", or "failed".
  public func agenticSearch(
    query: String,
    notebookId: String? = nil,
    limit: Int = 20
  ) async -> GraphQLAgenticSearchResult {
    guard let agentInvoker else {
      return GraphQLAgenticSearchResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "agent-unavailable"
      )
    }
    do {
      let search = AIAgenticSearchService(
        service: service,
        invoker: agentInvoker,
        provider: agentProvider,
        model: agentModel
      )
      let outcome = try await search.search(query: query, notebookId: notebookId, limit: limit)
      return GraphQLAgenticSearchResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: "ok",
        answerMarkdown: outcome.answerMarkdown
      )
    } catch {
      return GraphQLAgenticSearchResult(
        result: graphQLNoteResult(for: error),
        status: "failed"
      )
    }
  }

  public func appSetting(key: String) async -> GraphQLAppSettingResult {
    do {
      let value = try service.appSetting(key: key)
      return GraphQLAppSettingResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        key: key,
        valueJSON: value
      )
    } catch {
      return GraphQLAppSettingResult(result: graphQLNoteResult(for: error), key: key)
    }
  }

  public func setAppSetting(key: String, valueJSON: String) async -> GraphQLAppSettingResult {
    do {
      let stored = try service.setAppSetting(key: key, valueJSON: valueJSON)
      return GraphQLAppSettingResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        key: key,
        valueJSON: stored
      )
    } catch {
      return GraphQLAppSettingResult(result: graphQLNoteResult(for: error), key: key)
    }
  }

  /// Every memo in the notebook, note-anchored and notebook-level alike.
  public func notebookComments(
    notebookId: String
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteCommentDTO]> {
    noteResult {
      try service.listNotebookComments(notebookId: notebookId).map(GraphQLNoteCommentDTO.init)
    }
  }

  public func requestTagExtraction(
    _ input: GraphQLRequestTagExtractionInput
  ) async -> GraphQLTagExtractionRequestResult {
    do {
      let subject: AITagExtractionSubject
      switch (input.noteId, input.notebookId) {
      case (let noteId?, nil):
        subject = .note(noteId)
      case (nil, let notebookId?):
        subject = .notebook(notebookId)
      default:
        throw GraphQLNoteServiceError.invalidRequest(
          "requestTagExtraction requires exactly one of noteId or notebookId"
        )
      }
      let queued = try service.requestManualTagExtraction(subject: subject)
      return GraphQLTagExtractionRequestResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        status: queued ? "queued" : "agent-unavailable"
      )
    } catch {
      return GraphQLTagExtractionRequestResult(
        result: graphQLNoteResult(for: error),
        status: "error"
      )
    }
  }

  public func requestNotebookTranslation(
    _ input: GraphQLRequestNotebookTranslationInput
  ) async -> GraphQLNotebookTranslationRequestResult {
    do {
      let (notebook, queued) = try service.requestNotebookTranslation(
        sourceNotebookId: input.notebookId,
        targetLanguage: input.targetLanguage,
        title: input.title
      )
      return GraphQLNotebookTranslationRequestResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        translationNotebookId: notebook?.notebookId,
        status: queued ? "queued" : "agent-unavailable"
      )
    } catch {
      return GraphQLNotebookTranslationRequestResult(
        result: graphQLNoteResult(for: error),
        status: "error"
      )
    }
  }
}

private func estimatedBase64DecodedByteCount(_ value: String) -> Int {
  let sanitized = value.filter { !$0.isWhitespace }
  guard !sanitized.isEmpty else {
    return 0
  }
  let padding = sanitized.reversed().prefix { $0 == "=" }.count
  return max(0, (sanitized.count / 4) * 3 - padding)
}

enum GraphQLNoteServiceError: Error, Equatable {
  case invalidRequest(String)
}

private func graphQLNoteProvenance(_ rawValue: String) throws -> NoteProvenance {
  guard let provenance = NoteProvenance(rawValue: rawValue) else {
    throw GraphQLNoteServiceError.invalidRequest("unsupported note provenance: \(rawValue)")
  }
  return provenance
}

private func graphQLNoteListSort(_ rawValue: String?) throws -> NoteListSort {
  guard let rawValue else {
    return .createdAtDesc
  }
  guard let sort = NoteListSort(rawValue: rawValue) else {
    throw GraphQLNoteServiceError.invalidRequest("unsupported note sort: \(rawValue)")
  }
  return sort
}

private func noteResult<Value>(
  _ body: () throws -> Value
) -> GraphQLNoteQueryResult<Value> where Value: Codable & Equatable & Sendable {
  do {
    return GraphQLNoteQueryResult(result: .ok, value: try body())
  } catch {
    return GraphQLNoteQueryResult(result: graphQLNoteResult(for: error))
  }
}

private func noteMutation(_ body: () throws -> GraphQLNoteMutationResult) -> GraphQLNoteMutationResult {
  do {
    return try body()
  } catch {
    return GraphQLNoteMutationResult(result: graphQLNoteResult(for: error))
  }
}

private func noteControlResult(_ body: () throws -> Void) -> GraphQLControlPlaneResult {
  do {
    try body()
    return .ok
  } catch {
    return graphQLNoteResult(for: error)
  }
}

func graphQLNoteResult(for error: Error) -> GraphQLControlPlaneResult {
  switch error {
  case NoteServiceError.notFound:
    return .init(accepted: false, status: "not_found", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  case NoteServiceError.readOnly, NoteServiceError.protectedTag:
    return .init(accepted: false, status: "rejected", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  case NoteServiceError.invalidInput:
    return .init(accepted: false, status: "invalid_request", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  case NoteServiceError.progressConflict:
    return .init(accepted: false, status: "progress_conflict", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  case GraphQLNoteServiceError.invalidRequest:
    return .init(accepted: false, status: "invalid_request", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  default:
    return .init(accepted: false, status: "error", diagnostics: [graphQLNotePublicDiagnostic(for: error)])
  }
}

func graphQLNotePublicDiagnostic(for error: Error) -> String {
  switch error {
  case NoteServiceError.notFound:
    return "requested note resource was not found"
  case NoteServiceError.readOnly:
    return "note is read-only"
  case NoteServiceError.protectedTag:
    return "tag is protected"
  case let NoteServiceError.invalidInput(message):
    return "invalid note request: \(message)"
  case let NoteServiceError.progressConflict(expected, actual):
    return "notebook progress conflict: expected '\(expected)' but found '\(actual)'"
  case let NoteServiceError.invalidRow(message):
    return "invalid note store row: \(message)"
  case let GraphQLNoteServiceError.invalidRequest(message):
    return message
  case let NoteGraphQLDocumentExecutorError.missingVariable(name):
    return "missingVariable: \(name)"
  case let NoteGraphQLDocumentExecutorError.invalidVariable(message):
    return "invalidVariable: \(message)"
  case let NoteGraphQLDocumentExecutorError.invalidSelection(message):
    return "invalidSelection: \(message)"
  case let NoteGraphQLDocumentExecutorError.operationFieldMismatch(operation, fieldName):
    return "operationFieldMismatch: \(fieldName) cannot be used in \(operation)"
  default:
    return "note operation failed"
  }
}

private extension GraphQLControlPlaneResult {
  static let ok = GraphQLControlPlaneResult(accepted: true, status: "ok")
}
