import Foundation
import AppCore

public struct GraphQLIngestNotebookPageInput: Codable, Equatable, Sendable {
  public var bodyMarkdown: String
  public var readOnly: Bool?
  public var tags: [GraphQLNoteTagInput]?
  public var metaJSON: String?
  public var noteNumber: Int?
  public var pageImage: GraphQLIngestAttachmentInput?

  public init(
    bodyMarkdown: String,
    readOnly: Bool? = nil,
    tags: [GraphQLNoteTagInput]? = nil,
    metaJSON: String? = nil,
    noteNumber: Int? = nil,
    pageImage: GraphQLIngestAttachmentInput? = nil
  ) {
    self.bodyMarkdown = bodyMarkdown
    self.readOnly = readOnly
    self.tags = tags
    self.metaJSON = metaJSON
    self.noteNumber = noteNumber
    self.pageImage = pageImage
  }
}

public struct GraphQLIngestAttachmentInput: Codable, Equatable, Sendable {
  public var contentBase64: String
  public var mediaType: String
  public var originalFilename: String?
  public var role: String?
}

public struct GraphQLIngestNotebookPagesInput: Codable, Equatable, Sendable {
  public var idempotencyKey: String
  public var title: String
  public var kindTagName: String?
  public var metaJSON: String?
  public var pages: [GraphQLIngestNotebookPageInput]
  public var sourceDocument: GraphQLIngestAttachmentInput?
  public var originatingActionId: AutoActionID?

  public init(
    idempotencyKey: String,
    title: String,
    kindTagName: String? = nil,
    metaJSON: String? = nil,
    pages: [GraphQLIngestNotebookPageInput],
    sourceDocument: GraphQLIngestAttachmentInput? = nil,
    originatingActionId: AutoActionID? = nil
  ) {
    self.idempotencyKey = idempotencyKey
    self.title = title
    self.kindTagName = kindTagName
    self.metaJSON = metaJSON
    self.pages = pages
    self.sourceDocument = sourceDocument
    self.originatingActionId = originatingActionId
  }
}

public struct GraphQLLongTermMemoryEntryInput: Codable, Equatable, Sendable {
  public var bodyMarkdown: String
  public var topicTags: [String]?
  public var sourceNoteIds: [NoteID]?
  public var relatedNoteIds: [NoteID]?
  public var periodStart: String?
  public var periodEnd: String?
  public var metaJSON: String?

  var serviceInput: LongTermMemoryEntryInput {
    get throws {
      LongTermMemoryEntryInput(
        bodyMarkdown: bodyMarkdown,
        topicTags: topicTags ?? [],
        sourceNoteIds: sourceNoteIds ?? [],
        relatedNoteIds: relatedNoteIds ?? [],
        periodStart: try periodStart.map(graphQLLongTermMemoryDate),
        periodEnd: try periodEnd.map(graphQLLongTermMemoryDate),
        metaJSON: metaJSON
      )
    }
  }
}

public struct GraphQLAppendLongTermMemoryInput: Codable, Equatable, Sendable {
  public var idempotencyKey: String
  public var entries: [GraphQLLongTermMemoryEntryInput]
}

public struct GraphQLRecallLongTermMemoryInput: Codable, Equatable, Sendable {
  public var query: String
  public var limit: Int?
  public var includeAssociations: Bool?
  public var associationDepth: Int?
  public var recencyWeight: Double?
}

public struct GraphQLLongTermMemoryAppendPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var notes: [GraphQLNoteDTO]
  public var idempotentReplay: Bool
}

public struct GraphQLLongTermMemoryRecallHitDTO: Codable, Equatable, Sendable {
  public var note: GraphQLNoteDTO
  public var snippet: String
  public var rank: Double
  public var isAssociation: Bool
  public var edgeKind: String?
  public var weight: Double?
  public var hopCount: Int?
  public var pathNoteIds: [NoteID]

  init(_ hit: LongTermMemoryRecallResult) {
    note = GraphQLNoteDTO(note: hit.note)
    snippet = hit.snippet
    rank = hit.rank
    isAssociation = hit.isAssociation
    edgeKind = hit.edgeKind?.rawValue
    weight = hit.weight
    hopCount = hit.hopCount
    pathNoteIds = hit.pathNoteIds
  }
}

public struct GraphQLLongTermMemoryRecallPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var value: [GraphQLLongTermMemoryRecallHitDTO]
}

extension GraphQLNoteGraphQLService {
  public func ingestNotebookPages(
    _ input: GraphQLIngestNotebookPagesInput
  ) async -> GraphQLNoteMutationResult {
    do {
      let prepared = try prepareNotebookIngest(input)
      return try await resolveNotebookIngestClaim(prepared)
    } catch {
      return GraphQLNoteMutationResult(result: graphQLNoteResult(for: error))
    }
  }

  private func prepareNotebookIngest(
    _ input: GraphQLIngestNotebookPagesInput
  ) throws -> PreparedGraphQLNotebookIngest {
    guard !input.pages.isEmpty, input.pages.count <= 500 else {
      throw GraphQLNoteServiceError.invalidRequest("ingest requires 1...500 pages")
    }
    guard input.pages.allSatisfy({
      !$0.bodyMarkdown.isEmpty
        && $0.bodyMarkdown.utf8.count <= MarkdownHeadingSplitter.maximumSectionBytes
    }) else {
      throw GraphQLNoteServiceError.invalidRequest("ingest page is empty or exceeds the byte limit")
    }
    let effectiveNumbers = input.pages.enumerated().map { index, page in
      page.noteNumber ?? index + 1
    }
    guard effectiveNumbers.allSatisfy({ $0 > 0 }),
          Set(effectiveNumbers).count == effectiveNumbers.count else {
      throw GraphQLNoteServiceError.invalidRequest("ingest page numbers must be positive and unique")
    }
    for (index, page) in input.pages.enumerated() {
      try validateIngestPageMetadata(page.metaJSON, pageNumber: index + 1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let serializedBody = try encoder.encode(input)
    guard serializedBody.count <= GraphQLRequestLimits.maximumSerializedBodyBytes else {
      throw GraphQLNoteServiceError.invalidRequest("ingest request exceeds the serialized body byte limit")
    }
    let sourceDocument = try input.sourceDocument.map {
      let attachment = try decodedIngestAttachment(
        $0,
        defaultRole: NotebookFileRole.sourceDocument.rawValue
      )
      guard NotebookFileRole(rawValue: attachment.role) != nil else {
        throw GraphQLNoteServiceError.invalidRequest("unsupported source-document role")
      }
      return attachment
    }
    let pageImages = try input.pages.map { page in
      try page.pageImage.map {
        let attachment = try decodedIngestAttachment(
          $0,
          defaultRole: NoteFileRole.sourcePageImage.rawValue
        )
        guard NoteFileRole(rawValue: attachment.role) != nil else {
          throw GraphQLNoteServiceError.invalidRequest("unsupported page-image role")
        }
        return attachment
      }
    }
    let attachmentByteCount = (sourceDocument?.data.count ?? 0)
      + pageImages.compactMap { $0?.data.count }.reduce(0, +)
    guard attachmentByteCount <= graphQLIngestMaximumAttachmentBytes else {
      throw GraphQLNoteServiceError.invalidRequest("ingest attachments exceed the aggregate byte limit")
    }
    try service.validateNotebookIngestMetadata(input.metaJSON)
    var canonicalInput = input
    canonicalInput.idempotencyKey = ""
    return PreparedGraphQLNotebookIngest(
      input: input,
      canonicalRequest: try encoder.encode(canonicalInput),
      sourceDocument: sourceDocument,
      pageImages: pageImages
    )
  }

  private func resolveNotebookIngestClaim(
    _ prepared: PreparedGraphQLNotebookIngest
  ) async throws -> GraphQLNoteMutationResult {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: ingestClaimMaximumWait)
    var backoff = ingestClaimInitialBackoff
    while true {
      try Task.checkCancellation()
      let claim = try service.claimNotebookIngestRequest(
        idempotencyKey: prepared.input.idempotencyKey,
        canonicalRequest: prepared.canonicalRequest
      )
      ingestClaimObserver(claim)
      switch claim {
      case let .replay(resultJSON):
        return try decodedNotebookIngestResult(resultJSON)
      case let .pending(identity):
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
          throw GraphQLNoteServiceError.invalidRequest("ingest request is still in progress")
        }
        try await service.waitForNotebookIngestExecutionChange(
          identity,
          timeout: min(backoff, remaining)
        )
        backoff = min(backoff + backoff, ingestClaimMaximumBackoff)
      case let .recover(recovery):
        return recoverNotebookIngest(recovery)
      case let .resume(created):
        return await resumeCreatedNotebookIngest(prepared, created: created)
      case let .execute(identity):
        return await performClaimedNotebookIngest(prepared, identity: identity)
      }
    }
  }

  private func performClaimedNotebookIngest(
    _ prepared: PreparedGraphQLNotebookIngest,
    identity: NotebookIngestRequestIdentity,
    existingIngest: NotebookIngestResult? = nil
  ) async -> GraphQLNoteMutationResult {
    var shouldReleaseExecutionOnExit = true
    defer {
      if shouldReleaseExecutionOnExit {
        service.releaseNotebookIngestExecution(identity)
      }
    }
    let input = prepared.input
    var createdIngest = existingIngest
    do {
      let sourceDocument = prepared.sourceDocument
      let pageImages = prepared.pageImages
      let ingestService = service.pendingNotebookIngestScope()
      let ingest: NotebookIngestResult
      if let existingIngest {
        ingest = existingIngest
      } else {
        try ingestBeforeNotebookCreation()
        ingest = try service.createClaimedNotebookIngest(
          identity,
          title: input.title,
          kindTagName: input.kindTagName,
          callerMetadataJSON: input.metaJSON,
          pages: input.pages.map {
            NotePageDraft(
              bodyMarkdown: $0.bodyMarkdown,
              readOnly: false,
              tags: ($0.tags ?? []).map(\.noteInput),
              metaJSON: $0.metaJSON,
              noteNumber: $0.noteNumber
            )
          },
          originatingActionId: input.originatingActionId
        )
        createdIngest = ingest
        try ingestAfterNotebookCreation()
      }
      var committedNotebookFiles: [GraphQLNotebookFileAttachmentDTO] = []
      var committedNoteFiles: [GraphQLNoteFileAttachmentDTO] = []
      var postCreateFailures: [Error] = []
      do {
        if let sourceDocument {
          guard let role = NotebookFileRole(rawValue: sourceDocument.role) else {
            throw GraphQLNoteServiceError.invalidRequest("unsupported source-document role")
          }
          let attachment = try reusableNotebookAttachment(
            service: ingestService,
            notebookId: ingest.notebook.notebookId,
            attachment: sourceDocument,
            role: role
          ) ?? ingestService.attachNotebookFile(
              notebookId: ingest.notebook.notebookId,
              data: sourceDocument.data,
              role: role,
              mediaType: sourceDocument.mediaType,
              originalFilename: sourceDocument.originalFilename
            )
          committedNotebookFiles.append(GraphQLNotebookFileAttachmentDTO(attachment: attachment))
        }
        for (index, pageImage) in pageImages.enumerated() {
          guard let pageImage else { continue }
          guard let role = NoteFileRole(rawValue: pageImage.role) else {
            throw GraphQLNoteServiceError.invalidRequest("unsupported page-image role")
          }
          let position = input.pages[index].noteNumber ?? index + 1
          let attachment = try reusableNoteAttachment(
            service: ingestService,
            noteId: ingest.notes[index].noteId,
            attachment: pageImage,
            role: role,
            position: position
          ) ?? ingestNoteAttachmentMutation(
              ingestService,
              ingest.notes[index].noteId,
              pageImage.data,
              role,
              pageImage.mediaType,
              pageImage.originalFilename,
              position
            )
          committedNoteFiles.append(GraphQLNoteFileAttachmentDTO(attachment: attachment))
        }
      } catch {
        postCreateFailures.append(error)
      }
      try ingestAfterAttachmentPhase()

      var knownNotes = Dictionary(uniqueKeysWithValues: ingest.notes.map { ($0.noteId, $0) })
      for (note, page) in zip(ingest.notes, input.pages) where page.readOnly ?? true {
        do {
          knownNotes[note.noteId] = try ingestReadOnlyMutation(ingestService, note.noteId, true)
        } catch {
          postCreateFailures.append(error)
        }
      }
      for note in ingest.notes {
        do {
          knownNotes[note.noteId] = try ingestNoteReadback(ingestService, note.noteId)
        } catch {
          postCreateFailures.append(error)
        }
      }
      let reconciledNotes = ingest.notes.map { note in
        GraphQLNoteDTO(note: knownNotes[note.noteId] ?? note)
      }
      var notebookDTO = GraphQLNotebookDTO(notebook: ingest.notebook)
      notebookDTO.metaJSON = input.metaJSON
      let partialFailureResult: ([Error]) -> GraphQLNoteMutationResult = { failures in
        GraphQLNoteMutationResult(
          result: GraphQLControlPlaneResult(
            accepted: false,
            status: "partial-failure",
            diagnostics: failures.map(graphQLNotePublicDiagnostic)
          ),
          notebook: notebookDTO,
          notes: reconciledNotes,
          noteFiles: committedNoteFiles,
          notebookFiles: committedNotebookFiles
        )
      }
      guard postCreateFailures.isEmpty else {
        let result = partialFailureResult(postCreateFailures)
        return completeOrRecordNotebookIngestRecovery(
          result,
          identity: identity,
          ingest: ingest,
          enqueueAutoActions: false,
          originatingActionId: input.originatingActionId
        )
      }
      let result = GraphQLNoteMutationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        notebook: notebookDTO,
        notes: reconciledNotes,
        noteFiles: committedNoteFiles,
        notebookFiles: committedNotebookFiles
      )
      return completeOrRecordNotebookIngestRecovery(
        result,
        identity: identity,
        ingest: ingest,
        enqueueAutoActions: true,
        originatingActionId: input.originatingActionId
      )
    } catch {
      if createdIngest == nil {
        do {
          try service.abandonNotebookIngestRequest(identity)
          shouldReleaseExecutionOnExit = false
          ingestAfterAbandonment()
        } catch {
          // The deferred fallback still releases process-local ownership when
          // durable abandonment itself fails.
        }
      }
      return GraphQLNoteMutationResult(
        result: graphQLNoteResult(for: error)
      )
    }
  }

  private func resumeCreatedNotebookIngest(
    _ prepared: PreparedGraphQLNotebookIngest,
    created: NotebookIngestRequestCreated
  ) async -> GraphQLNoteMutationResult {
    do {
      let ingestService = service.pendingNotebookIngestScope()
      let ingest = NotebookIngestResult(
        notebook: try ingestService.getNotebook(created.notebookId),
        notes: try created.noteIds.map(ingestService.getNote)
      )
      return await performClaimedNotebookIngest(
        prepared,
        identity: created.identity,
        existingIngest: ingest
      )
    } catch {
      service.releaseNotebookIngestExecution(created.identity)
      return GraphQLNoteMutationResult(result: graphQLNoteResult(for: error))
    }
  }

  private func reusableNotebookAttachment(
    service: NoteService,
    notebookId: NotebookID,
    attachment: DecodedGraphQLIngestAttachment,
    role: NotebookFileRole
  ) throws -> NotebookFileAttachment? {
    let digest = sha256Hex(attachment.data)
    return try service.listFiles(notebookId: notebookId).first {
      $0.role == role
        && $0.file.sha256 == digest
        && $0.file.byteSize == Int64(attachment.data.count)
        && $0.file.mediaType == attachment.mediaType
        && $0.file.originalFilename == attachment.originalFilename
    }
  }

  private func reusableNoteAttachment(
    service: NoteService,
    noteId: NoteID,
    attachment: DecodedGraphQLIngestAttachment,
    role: NoteFileRole,
    position: Int
  ) throws -> NoteFileAttachment? {
    let digest = sha256Hex(attachment.data)
    return try service.listFiles(noteId: noteId).first {
      $0.role == role
        && $0.position == position
        && $0.file.sha256 == digest
        && $0.file.byteSize == Int64(attachment.data.count)
        && $0.file.mediaType == attachment.mediaType
        && $0.file.originalFilename == attachment.originalFilename
    }
  }

  private func completeNotebookIngest(
    _ result: GraphQLNoteMutationResult,
    identity: NotebookIngestRequestIdentity,
    ingest: NotebookIngestResult,
    enqueueAutoActions: Bool,
    originatingActionId: AutoActionID?
  ) throws {
    let resultJSON = try encodedNotebookIngestResult(result)
    try ingestCompletionMutation(
      service,
      identity,
      ingest,
      resultJSON,
      enqueueAutoActions,
      originatingActionId
    )
  }

  private func encodedNotebookIngestResult(_ result: GraphQLNoteMutationResult) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    guard let resultJSON = String(data: data, encoding: .utf8) else {
      throw NoteServiceError.invalidRow("ingest result is not UTF-8")
    }
    return resultJSON
  }

  private func completeOrRecordNotebookIngestRecovery(
    _ result: GraphQLNoteMutationResult,
    identity: NotebookIngestRequestIdentity,
    ingest: NotebookIngestResult,
    enqueueAutoActions: Bool,
    originatingActionId: AutoActionID?
  ) -> GraphQLNoteMutationResult {
    do {
      try completeNotebookIngest(
        result,
        identity: identity,
        ingest: ingest,
        enqueueAutoActions: enqueueAutoActions,
        originatingActionId: originatingActionId
      )
      return result
    } catch {
      do {
        try ingestRecoveryMutation(
          service,
          identity,
          ingest,
          try encodedNotebookIngestResult(result),
          enqueueAutoActions,
          originatingActionId
        )
      } catch {
        return notebookIngestCompletionPendingResult(result, error: error)
      }
      return notebookIngestCompletionPendingResult(result, error: error)
    }
  }

  private func recoverNotebookIngest(
    _ recovery: NotebookIngestRequestRecovery
  ) -> GraphQLNoteMutationResult {
    do {
      let result = try decodedNotebookIngestResult(recovery.resultJSON)
      let ingestService = service.pendingNotebookIngestScope()
      let ingest = NotebookIngestResult(
        notebook: try ingestService.getNotebook(recovery.notebookId),
        notes: try recovery.noteIds.map(ingestService.getNote)
      )
      try completeNotebookIngest(
        result,
        identity: recovery.identity,
        ingest: ingest,
        enqueueAutoActions: recovery.enqueueAutoActions,
        originatingActionId: recovery.originatingActionId
      )
      return result
    } catch {
      if let completed = try? service.completedNotebookIngestResult(recovery.identity),
         let result = try? decodedNotebookIngestResult(completed) {
        return result
      }
      guard let result = try? decodedNotebookIngestResult(recovery.resultJSON) else {
        return GraphQLNoteMutationResult(result: graphQLNoteResult(for: error))
      }
      return notebookIngestCompletionPendingResult(result, error: error)
    }
  }

  private func notebookIngestCompletionPendingResult(
    _ terminalResult: GraphQLNoteMutationResult,
    error: Error
  ) -> GraphQLNoteMutationResult {
    var pending = terminalResult
    pending.result = GraphQLControlPlaneResult(
      accepted: false,
      status: "retryable",
      diagnostics: [graphQLNotePublicDiagnostic(for: error)]
    )
    return pending
  }

  private func decodedNotebookIngestResult(_ resultJSON: String) throws -> GraphQLNoteMutationResult {
    try JSONDecoder().decode(GraphQLNoteMutationResult.self, from: Data(resultJSON.utf8))
  }

  public func longTermMemoryNotebook() async -> GraphQLNoteQueryResult<GraphQLNotebookDTO> {
    noteResult { GraphQLNotebookDTO(notebook: try service.longTermMemoryNotebook()) }
  }

  public func appendLongTermMemory(
    _ input: GraphQLAppendLongTermMemoryInput,
    assignedBy: String? = nil
  ) async -> GraphQLLongTermMemoryAppendPayload {
    do {
      let append = try service.appendLongTermMemoryNotes(
        try input.entries.map { try $0.serviceInput },
        idempotencyKey: input.idempotencyKey,
        assignedBy: assignedBy ?? NoteService.longTermMemoryAssignedBy
      )
      return GraphQLLongTermMemoryAppendPayload(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        notes: append.notes.map(GraphQLNoteDTO.init),
        idempotentReplay: append.idempotentReplay
      )
    } catch {
      return GraphQLLongTermMemoryAppendPayload(
        result: graphQLNoteResult(for: error),
        notes: [],
        idempotentReplay: false
      )
    }
  }

  public func recallLongTermMemory(
    _ input: GraphQLRecallLongTermMemoryInput
  ) async -> GraphQLLongTermMemoryRecallPayload {
    do {
      let hits = try service.recallLongTermMemories(
        query: input.query,
        limit: input.limit ?? 20,
        includeAssociations: input.includeAssociations ?? false,
        associationDepth: input.associationDepth ?? NoteGraphPolicy.associationMaxDepth,
        recencyWeight: input.recencyWeight ?? NoteService.longTermMemoryDefaultRecencyWeight
      )
      return GraphQLLongTermMemoryRecallPayload(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        value: hits.map(GraphQLLongTermMemoryRecallHitDTO.init)
      )
    } catch {
      return GraphQLLongTermMemoryRecallPayload(
        result: graphQLNoteResult(for: error),
        value: []
      )
    }
  }

  public func linkLongTermMemoryAssociations(
    noteId: NoteID,
    limit: Int
  ) async -> GraphQLNoteQueryResult<[GraphQLNoteLinkDTO]> {
    noteResult {
      try service.linkLongTermMemoryAssociations(noteId: noteId, limit: limit)
        .map(GraphQLNoteLinkDTO.init)
    }
  }
}

private let graphQLIngestMaximumAttachmentBytes = 8 * 1024 * 1024

private struct PreparedGraphQLNotebookIngest: Sendable {
  let input: GraphQLIngestNotebookPagesInput
  let canonicalRequest: Data
  let sourceDocument: DecodedGraphQLIngestAttachment?
  let pageImages: [DecodedGraphQLIngestAttachment?]
}

private struct DecodedGraphQLIngestAttachment: Sendable {
  let data: Data
  let mediaType: String
  let originalFilename: String?
  let role: String
}

private func validateIngestPageMetadata(_ metaJSON: String?, pageNumber: Int) throws {
  guard let metaJSON else { return }
  guard let metadata = (try? JSONValue(parsing: metaJSON))?.asObject else {
    throw GraphQLNoteServiceError.invalidRequest(
      "ingest page \(pageNumber) metaJSON must encode a JSON object"
    )
  }
  guard metadata["kaibaChat"] == nil else {
    throw GraphQLNoteServiceError.invalidRequest("kaibaChat note metadata is server-managed")
  }
}

private func decodedIngestAttachment(
  _ input: GraphQLIngestAttachmentInput,
  defaultRole: String
) throws -> DecodedGraphQLIngestAttachment {
  let mediaTypePattern = #"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$"#
  guard input.mediaType.range(of: mediaTypePattern, options: .regularExpression) != nil,
        let data = Data(base64Encoded: input.contentBase64),
        data.count <= graphQLIngestMaximumAttachmentBytes else {
    throw GraphQLNoteServiceError.invalidRequest("ingest attachment is invalid or exceeds the byte limit")
  }
  if let filename = input.originalFilename,
     filename.isEmpty || filename.utf8.count > 255
       || filename == "." || filename == ".."
       || filename.contains("/") || filename.contains("\\")
       || filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
    throw GraphQLNoteServiceError.invalidRequest("ingest attachment filename is invalid")
  }
  return DecodedGraphQLIngestAttachment(
    data: data,
    mediaType: input.mediaType,
    originalFilename: input.originalFilename,
    role: input.role ?? defaultRole
  )
}

private func graphQLLongTermMemoryDate(_ value: String) throws -> Date {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) {
    return date
  }
  let wholeSeconds = ISO8601DateFormatter()
  wholeSeconds.formatOptions = [.withInternetDateTime]
  guard let date = wholeSeconds.date(from: value) else {
    throw GraphQLNoteServiceError.invalidRequest("long-term memory timestamp must be ISO-8601")
  }
  return date
}
