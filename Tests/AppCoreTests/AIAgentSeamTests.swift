import Foundation
@testable import AppCore
import XCTest

private struct StubInvoker: AgentInvoking {
  var reply: String
  var error: AgentInvocationError?

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    if let error {
      throw error
    }
    return AgentInvocationResult(markdown: reply)
  }
}

final class AIConfigurationTests: NoteTestCase {
  func testDecodesAISection() throws {
    let json = """
    {
      "ai": {
        "agent": {
          "backend": "agent-gateway-cli",
          "provider": "openrouter",
          "model": "test-model"
        },
        "autoTag": { "auto": "on" }
      },
      "import": {
        "ocr": {
          "commandPath": "/opt/bin/agent-gateway",
          "vendor": "codex",
          "model": "gpt-5.6-luna"
        }
      }
    }
    """
    let configuration = try JSONDecoder().decode(
      KaibaConfiguration.self,
      from: Data(json.utf8)
    )
    XCTAssertEqual(configuration.ai?.agent?.backend, "agent-gateway-cli")
    XCTAssertEqual(configuration.ai?.agent?.provider, "openrouter")
    XCTAssertEqual(configuration.ai?.agent?.model, "test-model")
    XCTAssertTrue(configuration.ai?.autoTagEnabled == true)
    XCTAssertEqual(configuration.importSettings?.ocr?.commandPath, "/opt/bin/agent-gateway")
    XCTAssertEqual(configuration.importSettings?.ocr?.vendor, "codex")
    XCTAssertEqual(configuration.importSettings?.ocr?.model, "gpt-5.6-luna")
  }

  func testAbsentAISectionDefaults() throws {
    let configuration = try JSONDecoder().decode(
      KaibaConfiguration.self,
      from: Data("{}".utf8)
    )
    XCTAssertNil(configuration.ai)
    XCTAssertNil(configuration.importSettings)
    XCTAssertNil(AgentInvokerFactory.makeInvoker(configuration: configuration.ai))
  }

  func testInvokerFactoryReturnsNilUntilAdapterExists() {
    let configuration = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli")
    )
    XCTAssertNil(AgentInvokerFactory.makeInvoker(configuration: configuration))
    XCTAssertTrue(
      AgentInvokerFactory.describeAvailability(configuration: configuration)
        .contains("agent-gateway")
    )
  }
}

final class AITagProposalParsingTests: NoteTestCase {
  private let allowed: Set<TagClassID> = [.person, .topic, .year]

  func testParsesPlainJSONArray() throws {
    let proposals = try AITagExtractionService.parseProposals(
      reply: #"[{"name":"swift","class":"topic"},{"name":"2026","class":"year"}]"#,
      allowedClassIds: allowed
    )
    XCTAssertEqual(proposals.map(\.name), ["swift", "2026"])
    XCTAssertEqual(proposals[0].class, .topic)
  }

  func testParsesFencedReply() throws {
    let reply = """
    Here are the tags:
    ```json
    [{"name":"cloudflare-workers","class":"topic","parent":"cloud"}]
    ```
    """
    let proposals = try AITagExtractionService.parseProposals(
      reply: reply,
      allowedClassIds: allowed
    )
    XCTAssertEqual(proposals.count, 1)
    XCTAssertEqual(proposals[0].parent, "cloud")
  }

  func testRejectsFolderAndUnknownClassesAndDuplicates() throws {
    let reply = """
    [
      {"name":"keep","class":"topic"},
      {"name":"drop-folder","class":"folder"},
      {"name":"drop-unknown","class":"mystery"},
      {"name":"notebook-kind:imported-material","class":"topic"},
      {"name":"KEEP","class":"topic"},
      {"name":"  "}
    ]
    """
    let proposals = try AITagExtractionService.parseProposals(
      reply: reply,
      allowedClassIds: allowed
    )
    XCTAssertEqual(proposals.map(\.name), ["keep"])
  }

  func testThrowsOnNonArrayReply() {
    XCTAssertThrowsError(try AITagExtractionService.parseProposals(
      reply: "I could not find any tags.",
      allowedClassIds: allowed
    ))
  }
}

final class AITagExtractionServiceTests: NoteTestCase {
  func testExtractsAndAppliesTagsToNoteWithProvenanceAI() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Swift Concurrency\nNotes.")
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(
        reply: #"[{"name":"swift-concurrency","class":"topic","parent":"swift"}]"#
      )
    )
    let result = try await extraction.extractTags(subject: .note(note.noteId))
    XCTAssertTrue(result.applied)

    let tagged = try service.getNote(note.noteId)
    let assignment = try XCTUnwrap(
      tagged.tags.first { $0.tag.name == "swift-concurrency" }
    )
    XCTAssertEqual(assignment.provenance, .ai)
    XCTAssertEqual(assignment.assignedBy, AITagExtractionService.assignedBy)
    XCTAssertEqual(assignment.tag.classId, TagClassID("topic"))
    let parent = try XCTUnwrap(try service.listTags().first { $0.name == "swift" })
    XCTAssertEqual(assignment.tag.parentTagId, parent.tagId)
  }

  func testDryRunDoesNotApply() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Something\nBody.")
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"something","class":"topic"}]"#)
    )
    let result = try await extraction.extractTags(subject: .note(note.noteId), dryRun: true)
    XCTAssertFalse(result.applied)
    XCTAssertEqual(result.proposals.count, 1)
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
  }

  func testAppliesNotebookLevelTags() async throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Imported Book",
      kindTagName: NoteStoreSchema.importedMaterialNotebookKindTag,
      pages: [NotePageDraft(bodyMarkdown: "# Imported Book\nText.")]
    )
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"reading","class":"topic"}]"#)
    )
    let result = try await extraction.extractTags(
      subject: .notebook(ingest.notebook.notebookId)
    )
    XCTAssertTrue(result.applied)
    let notebook = try service.getNotebook(ingest.notebook.notebookId)
    let assignment = try XCTUnwrap(notebook.tags.first { $0.tag.name == "reading" })
    XCTAssertEqual(assignment.provenance, .ai)
  }

  func testSkipsAgentConversationNotebooks() async throws {
    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody.")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "What is this?",
      agentAvailable: false
    )
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"never","class":"topic"}]"#)
    )
    let noteResult = try await extraction.extractTags(subject: .note(turn.noteId))
    XCTAssertFalse(noteResult.applied)
    XCTAssertTrue(noteResult.proposals.isEmpty)
    let notebookResult = try await extraction.extractTags(
      subject: .notebook(conversation.notebookId)
    )
    XCTAssertFalse(notebookResult.applied)
  }

  func testAINeverRedefinesAnExistingTag() async throws {
    let service = try makeService()
    _ = try service.defineTag(name: "existing-plain")
    let note = try service.createNote(bodyMarkdown: "# Doc\nBody.")
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"existing-plain","class":"topic"}]"#)
    )
    _ = try await extraction.extractTags(subject: .note(note.noteId))
    let tag = try XCTUnwrap(try service.listTags().first { $0.name == "existing-plain" })
    XCTAssertNil(tag.classId, "AI must not reclassify an existing tag")
    XCTAssertTrue(
      try service.getNote(note.noteId).tags.contains { $0.tag.name == "existing-plain" },
      "the assignment itself must still be applied"
    )
  }

  func testAINeverOverwritesHumanTagAssignment() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Owned\nBody.")
    _ = try service.applyTags(
      noteId: note.noteId,
      tags: [NoteTagInput(name: "owned-tag")],
      provenance: .human,
      assignedBy: "human-user"
    )
    let extraction = AITagExtractionService(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"owned-tag","class":"topic"}]"#)
    )
    _ = try await extraction.extractTags(subject: .note(note.noteId))
    let assignment = try XCTUnwrap(
      try service.getNote(note.noteId).tags.first { $0.tag.name == "owned-tag" }
    )
    XCTAssertEqual(assignment.provenance, .human, "AI must never overwrite a human tag")
    XCTAssertEqual(assignment.assignedBy, "human-user")
  }
}

final class KaibaAutoActionDispatcherTests: NoteTestCase {
  private func record(
    workflowId: WorkflowID,
    trigger: NoteAutoActionTrigger,
    noteId: NoteID? = nil,
    notebookId: NotebookID? = nil
  ) -> AutoActionDispatchRecord {
    AutoActionDispatchRecord(
      action: AutoAction(
        actionId: AutoActionID("test-action"),
        trigger: trigger,
        workflowId: workflowId,
        filterJSON: nil,
        enabled: true,
        position: 0,
        createdAt: "2026-08-12T00:00:00Z"
      ),
      event: NoteAutoActionEvent(
        trigger: trigger,
        notebookId: notebookId,
        noteId: noteId,
        originatingUserId: nil,
        originatingIsUnauthenticatedPrincipal: false
      )
    )
  }

  func testUnknownWorkflowFails() async throws {
    let service = try makeService()
    let dispatcher = KaibaAutoActionDispatcher(
      service: service,
      invoker: StubInvoker(reply: "[]")
    )
    let outcome = try await dispatcher.dispatch(
      record(workflowId: WorkflowID("mystery"), trigger: .noteCreated, noteId: NoteID("n1"))
    )
    guard case .failed(let message) = outcome else {
      return XCTFail("expected failure")
    }
    XCTAssertTrue(message.contains("mystery"))
  }

  func testTagExtractionRoutingNoteAndNotebook() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Doc\nBody.")
    let dispatcher = KaibaAutoActionDispatcher(
      service: service,
      invoker: StubInvoker(reply: #"[{"name":"routed","class":"topic"}]"#)
    )
    let noteOutcome = try await dispatcher.dispatch(record(
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      trigger: .noteCreated,
      noteId: note.noteId
    ))
    XCTAssertEqual(noteOutcome, .succeeded)
    XCTAssertTrue(try service.getNote(note.noteId).tags.contains { $0.tag.name == "routed" })

    let notebookOutcome = try await dispatcher.dispatch(record(
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      trigger: .notebookCreated,
      notebookId: note.notebookId
    ))
    XCTAssertEqual(notebookOutcome, .succeeded)
  }

  func testInvokerFailureReturnsFailedOutcome() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Doc\nBody.")
    let dispatcher = KaibaAutoActionDispatcher(
      service: service,
      invoker: StubInvoker(reply: "", error: .unavailable("binary missing"))
    )
    let outcome = try await dispatcher.dispatch(record(
      workflowId: NoteStoreSchema.autoTaggingWorkflowId,
      trigger: .noteCreated,
      noteId: note.noteId
    ))
    guard case .failed = outcome else {
      return XCTFail("expected failure")
    }
  }
}

final class AIAutoActionReconciliationTests: NoteTestCase {
  private func enabledActionIds(_ service: NoteService) throws -> Set<AutoActionID> {
    Set(try service.listAutoActions().filter(\.enabled).map(\.actionId))
  }

  func testEnablesTaggingAndChatWhenConfiguredAndAvailable() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let configuration = KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli"),
      autoTag: KaibaAutoTagConfiguration(auto: .on)
    )
    try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: configuration,
      invokerAvailable: true
    )
    let enabled = try enabledActionIds(service)
    XCTAssertTrue(enabled.contains(AutoActionID("default-ai-tagging-note-created")))
    XCTAssertTrue(enabled.contains(AutoActionID("default-ai-tagging-note-updated")))
    XCTAssertTrue(enabled.contains(AutoActionID("default-ai-tagging-notebook-created")))
    XCTAssertTrue(enabled.contains(NoteStoreSchema.agentChatReplyActionId))

    let chatAction = try XCTUnwrap(
      try service.listAutoActions().first {
        $0.actionId == NoteStoreSchema.agentChatReplyActionId
      }
    )
    XCTAssertEqual(chatAction.workflowId, NoteStoreSchema.agentChatReplyWorkflowId)
    XCTAssertEqual(chatAction.trigger, .noteCreated)
    XCTAssertTrue(chatAction.filterJSON?.contains("agent-conversation") == true)
  }

  func testAutoTagOffKeepsTaggingDisabledButChatOn() throws {
    let service = try NoteService(driver: makeNoteDriver())
    try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: KaibaAIConfiguration(
        agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli")
      ),
      invokerAvailable: true
    )
    let enabled = try enabledActionIds(service)
    XCTAssertFalse(enabled.contains(AutoActionID("default-ai-tagging-note-created")))
    XCTAssertTrue(enabled.contains(NoteStoreSchema.agentChatReplyActionId))
  }

  func testNoInvokerForceDisablesEverything() throws {
    let service = try NoteService(driver: makeNoteDriver())
    // Simulate a previous run that enabled the actions.
    try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: KaibaAIConfiguration(
        agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli"),
        autoTag: KaibaAutoTagConfiguration(auto: .on)
      ),
      invokerAvailable: true
    )
    try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: KaibaAIConfiguration(
        agent: KaibaAgentBackendConfiguration(backend: "agent-gateway-cli"),
        autoTag: KaibaAutoTagConfiguration(auto: .on)
      ),
      invokerAvailable: false
    )
    XCTAssertTrue(try enabledActionIds(service).isEmpty)
  }
}
