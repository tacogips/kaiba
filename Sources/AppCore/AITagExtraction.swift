import Foundation

/// One tag proposed by the agent. `class` must name an existing non-folder
/// tag class; `parent` optionally names a parent tag for the hierarchy.
public struct AITagProposal: Codable, Equatable, Sendable {
  public var name: String
  public var `class`: TagClassID?
  public var parent: String?

  public init(name: String, class classId: TagClassID? = nil, parent: String? = nil) {
    self.name = name
    self.class = classId
    self.parent = parent
  }
}

public enum AITagExtractionSubject: Equatable, Sendable {
  case note(NoteID)
  case notebook(NotebookID)
}

public struct AITagExtractionResult: Equatable, Sendable {
  public var subject: AITagExtractionSubject
  public var proposals: [AITagProposal]
  public var applied: Bool

  public init(subject: AITagExtractionSubject, proposals: [AITagProposal], applied: Bool) {
    self.subject = subject
    self.proposals = proposals
    self.applied = applied
  }
}

public extension NoteService {
  static let manualTagExtractionActionId = AutoActionID("manual-tag-extraction")

  /// Queues a manual tag-extraction dispatch for the subject (the UI's
  /// "extract tags" button and the GraphQL `requestTagExtraction` mutation).
  /// Returns false when no dispatcher is installed (agent unavailable);
  /// nothing is queued in that case, so the outbox never accumulates rows
  /// that nothing will drain.
  @discardableResult
  func requestManualTagExtraction(subject: AITagExtractionSubject) throws -> Bool {
    let event: NoteAutoActionEvent
    let trigger: NoteAutoActionTrigger
    switch subject {
    case .note(let noteId):
      let note = try getNote(noteId)
      trigger = .noteUpdated
      event = NoteAutoActionEvent(
        trigger: trigger,
        notebookId: note.notebookId,
        noteId: noteId
      )
    case .notebook(let notebookId):
      _ = try getNotebook(notebookId)
      trigger = .notebookCreated
      event = NoteAutoActionEvent(trigger: trigger, notebookId: notebookId)
    }
    guard autoActionDispatcher != nil else {
      return false
    }
    let action = AutoAction(
      actionId: Self.manualTagExtractionActionId,
      trigger: trigger,
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      filterJSON: nil,
      enabled: true,
      position: 0,
      createdAt: NoteStoreClock.system.now()
    )
    let queued = try driver.withDatabase { database in
      try database.transaction { db in
        try enqueueManualAutoActionDispatch(action: action, event: event, in: db)
      }
    }
    dispatchQueuedAutoActions([queued])
    return true
  }
}

extension NoteService {
  /// Direct single-dispatch insert used by manual requests; mirrors the row
  /// shape written by `enqueueAutoActions` without requiring an enabled
  /// `auto_actions` row (a manual request must work even when autoTag is off).
  func enqueueManualAutoActionDispatch(
    action: AutoAction,
    event: NoteAutoActionEvent,
    in database: SQLiteDatabase
  ) throws -> QueuedAutoActionDispatch {
    let dispatchId = AutoActionDispatchID.generate()
    let now = NoteStoreClock.system.now()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let eventJSON = String(data: try encoder.encode(event), encoding: .utf8) else {
      throw NoteServiceError.invalidInput("auto action event JSON must be UTF-8")
    }
    try database.execute(
      """
      INSERT INTO auto_action_dispatches (
        dispatch_id, action_id, action_trigger, workflow_id, filter_json,
        action_enabled, action_position, action_created_at, event_json,
        status, attempt_count, created_at, updated_at
      ) VALUES (?, ?, ?, ?, jsonb(?), ?, ?, ?, jsonb(?), 'pending', 0, ?, ?)
      """,
      bindings: [
        .id(dispatchId),
        .id(action.actionId),
        .text(action.trigger.rawValue),
        .id(action.workflowId),
        .optionalText(action.filterJSON),
        .int(action.enabled ? 1 : 0),
        .int(Int64(action.position)),
        .text(action.createdAt),
        .text(eventJSON),
        .text(now),
        .text(now)
      ]
    )
    return QueuedAutoActionDispatch(
      dispatchId: dispatchId,
      record: AutoActionDispatchRecord(action: action, event: event)
    )
  }
}

/// Ontology tag extraction (`design-docs/specs/ai-agent-integration.md`, AI3):
/// builds the prompt with an ontology snapshot, validates the strict-JSON
/// reply, and applies accepted tags with provenance `ai`. The existing
/// assignment APIs guarantee AI never overwrites or deletes a human tag.
public struct AITagExtractionService: Sendable {
  public static let assignedBy = "kaiba-ai-tagger"
  /// Context cap keeps prompts bounded for large imported documents.
  static let maximumContextBytes = 200 * 1024

  public var service: NoteService
  public var invoker: any AgentInvoking
  public var provider: String?
  public var model: String?

  public init(
    service: NoteService,
    invoker: any AgentInvoking,
    provider: String? = nil,
    model: String? = nil
  ) {
    self.service = service
    self.invoker = invoker
    self.provider = provider
    self.model = model
  }

  /// Extracts tags for the subject and applies them unless `dryRun`.
  public func extractTags(
    subject: AITagExtractionSubject,
    dryRun: Bool = false
  ) async throws -> AITagExtractionResult {
    let context = try subjectContext(for: subject)
    if context.isAgentConversation {
      return AITagExtractionResult(subject: subject, proposals: [], applied: false)
    }
    let classes = try service.listTagClasses().filter { $0.classId != .folder }
    let existingTags = try service.listTags().filter { $0.classId != .folder }
    let request = AgentInvocationRequest(
      purpose: .tagExtraction,
      systemPrompt: Self.systemPrompt(classes: classes, existingTags: existingTags),
      turns: [AgentInvocationTurn(role: .user, markdown: context.markdown)],
      contextMarkdown: nil,
      provider: provider,
      model: model
    )
    let reply = try await invoker.invoke(request)
    let proposals = try Self.parseProposals(
      reply: reply.markdown,
      allowedClassIds: Set(classes.map(\.classId))
    )
    guard !dryRun, !proposals.isEmpty else {
      return AITagExtractionResult(subject: subject, proposals: proposals, applied: false)
    }
    try apply(proposals: proposals, to: subject)
    return AITagExtractionResult(subject: subject, proposals: proposals, applied: true)
  }

  // MARK: - Prompt

  static func systemPrompt(classes: [TagClass], existingTags: [Tag]) -> String {
    let classLines = classes
      .map { "- \($0.classId): \($0.label)\($0.description.map { " (\($0))" } ?? "")" }
      .joined(separator: "\n")
    let tagNames = existingTags.map(\.name).sorted().prefix(400).joined(separator: ", ")
    return """
    You extract ontology tags for a note-taking system. Given a document, \
    propose concise tags that classify it within a world model.

    Available tag classes:
    \(classLines)

    Existing tags (reuse exact names when they fit): \(tagNames)

    Reply with ONLY a JSON array, no prose, no code fences, of objects:
    [{"name": "tag-name", "class": "class-id", "parent": "parent-tag-name"}]
    - "name" is required: lowercase, hyphenated, specific.
    - "class" is optional but strongly preferred; it must be one of the class \
    ids listed above.
    - "parent" is optional: the name of a broader existing or proposed tag.
    - Propose at most 8 tags. Never propose folder tags or system tags
    (names starting with "notebook-kind:").
    """
  }

  // MARK: - Reply validation

  public static func parseProposals(
    reply: String,
    allowedClassIds: Set<TagClassID>
  ) throws -> [AITagProposal] {
    let json = extractJSONArray(from: reply)
    guard let data = json.data(using: .utf8) else {
      throw AgentInvocationError.failed("tag extraction reply is not UTF-8")
    }
    let decoded: [AITagProposal]
    do {
      decoded = try JSONDecoder().decode([AITagProposal].self, from: data)
    } catch {
      throw AgentInvocationError.failed(
        "tag extraction reply is not a JSON array of {name, class?, parent?}"
      )
    }
    var seen = Set<String>()
    var accepted: [AITagProposal] = []
    for proposal in decoded {
      let name = proposal.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, seen.insert(name.lowercased()).inserted else {
        continue
      }
      // Reserved system namespace: notebook kinds are never assignable by AI.
      guard !name.hasPrefix("notebook-kind:") else {
        continue
      }
      if let classId = proposal.class {
        guard classId != .folder, allowedClassIds.contains(classId) else {
          continue
        }
      }
      let parent = proposal.parent?.trimmingCharacters(in: .whitespacesAndNewlines)
      accepted.append(AITagProposal(
        name: name,
        class: proposal.class,
        parent: parent?.isEmpty == true ? nil : parent
      ))
    }
    return accepted
  }

  /// Tolerates replies that wrap the array in code fences or prose.
  static func extractJSONArray(from reply: String) -> String {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") {
      return trimmed
    }
    guard let start = trimmed.firstIndex(of: "["),
      let end = trimmed.lastIndex(of: "]"),
      start < end
    else {
      return trimmed
    }
    return String(trimmed[start...end])
  }

  // MARK: - Application

  private func apply(proposals: [AITagProposal], to subject: AITagExtractionSubject) throws {
    // AI may create missing tags but never redefines an existing tag's class
    // or parent — reclassifying a human-authored tag is a silent ontology
    // mutation, not an assignment (which D6 already protects).
    var existingNames = Set(
      try service.listTags().filter { $0.classId != .folder }.map(\.name)
    )
    for proposal in proposals {
      var parentTagId: TagID?
      if let parentName = proposal.parent {
        if existingNames.contains(parentName) {
          parentTagId = try service.listTags()
            .first { $0.name == parentName && $0.classId != .folder }?.tagId
        } else {
          let parent = try service.defineTag(name: parentName, classId: proposal.class)
          existingNames.insert(parentName)
          parentTagId = parent.tagId
        }
      }
      if !existingNames.contains(proposal.name) {
        _ = try service.defineTag(
          name: proposal.name,
          classId: proposal.class,
          parentTagId: parentTagId
        )
        existingNames.insert(proposal.name)
      }
    }
    let names = proposals.map(\.name)
    switch subject {
    case .note(let noteId):
      _ = try service.applyTags(
        noteId: noteId,
        tags: names.map { NoteTagInput(name: $0) },
        provenance: .ai,
        assignedBy: Self.assignedBy
      )
    case .notebook(let notebookId):
      _ = try service.applyNotebookTags(
        notebookId: notebookId,
        tags: names,
        provenance: .ai,
        assignedBy: Self.assignedBy
      )
    }
  }

  // MARK: - Subject context

  private struct SubjectContext {
    var markdown: String
    var isAgentConversation: Bool
  }

  private func subjectContext(for subject: AITagExtractionSubject) throws -> SubjectContext {
    switch subject {
    case .note(let noteId):
      let note = try service.getNote(noteId)
      let notebook = try service.getNotebook(note.notebookId)
      return SubjectContext(
        markdown: Self.capped(note.bodyMarkdown),
        isAgentConversation: Self.isAgentConversation(notebook)
      )
    case .notebook(let notebookId):
      let notebook = try service.getNotebook(notebookId)
      let notes = try service.listNotes(notebookId: notebookId, limit: 50, offset: 0)
      var markdown = "# Notebook: \(notebook.title)\n"
      for note in notes {
        markdown += "\n## \(note.title ?? "(untitled)")\n"
        markdown += note.bodyMarkdown.prefix(4_000)
        markdown += "\n"
      }
      return SubjectContext(
        markdown: Self.capped(markdown),
        isAgentConversation: Self.isAgentConversation(notebook)
      )
    }
  }

  static func isAgentConversation(_ notebook: Notebook) -> Bool {
    notebook.tags.contains {
      $0.tag.name == NoteStoreSchema.agentConversationNotebookKindTag
    }
  }

  private static func capped(_ markdown: String) -> String {
    guard markdown.utf8.count > maximumContextBytes else {
      return markdown
    }
    return String(markdown.prefix(maximumContextBytes))
  }
}
