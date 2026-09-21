import Foundation
@testable import AppCore
import XCTest

private actor DocumentTagInvoker: AgentInvoking {
  var requests: [AgentInvocationRequest] = []
  let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    requests.append(request)
    if fails { throw AgentInvocationError.failed("private provider diagnostic") }
    return AgentInvocationResult(markdown: #"[{"name":"registered-topic","class":"topic"}]"#)
  }
}

final class DocumentAutoTaggingTests: NoteTestCase {
  func testServerDispatcherDefersPendingPageThenTagsRecognizedText() async throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("stored image".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: TaggingPageRecognizer()), maximumOCRPages: 0
    )
    let note = try XCTUnwrap(imported.notes.first)
    let invoker = DocumentTagInvoker()
    let dispatcher = KaibaAutoActionDispatcher(
      service: service, invoker: invoker, tagRegistrationPrompt: "Use the registered topic."
    )
    let record = AutoActionDispatchRecord(
      action: AutoAction(
        actionId: AutoActionID("test-import-tagging"), trigger: .noteUpdated,
        workflowId: NoteStoreSchema.autoTaggingWorkflowId, filterJSON: nil, enabled: true,
        position: 0, createdAt: "2026-09-13T00:00:00Z"
      ),
      event: NoteAutoActionEvent(
        trigger: .noteUpdated, notebookId: note.notebookId, noteId: note.noteId,
        originatingUserId: nil, originatingIsUnauthenticatedPrincipal: false
      )
    )
    _ = try await dispatcher.dispatch(record)
    let pendingRequests = await invoker.requests
    XCTAssertTrue(pendingRequests.isEmpty)
    _ = try service.recognizeDocumentPage(noteId: note.noteId, recognizer: TaggingPageRecognizer())
    _ = try await dispatcher.dispatch(record)
    let completedRequests = await invoker.requests
    XCTAssertEqual(completedRequests.count, 1)
    XCTAssertTrue(completedRequests.first?.systemPrompt.contains("Use the registered topic.") == true)
    XCTAssertEqual(completedRequests.first?.turns.first?.markdown, "Recognized graph algorithms")
    XCTAssertTrue(try service.getNote(note.noteId).tags.contains { $0.tag.name == "registered-topic" })
  }

  func testManualOCRMakesPendingImportedPageEligibleForTags() async throws {
    let service = try makeService()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Data("stored image".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let imported = try service.importDocumentPages(
      at: source.path, processor: DocumentPageProcessor(recognizer: TaggingPageRecognizer()), maximumOCRPages: 0
    )
    let invoker = DocumentTagInvoker()
    let tagging = DocumentAutoTagging(
      service: service, configuration: KaibaAIConfiguration(autoTag: KaibaAutoTagConfiguration(auto: .on)), invoker: invoker
    )
    let note = try XCTUnwrap(imported.notes.first)
    let firstWarnings = await tagging.tag(notebookId: note.notebookId, noteIds: [note.noteId])
    XCTAssertTrue(firstWarnings.isEmpty)
    XCTAssertTrue(try service.getNote(note.noteId).tags.isEmpty)
    _ = try service.recognizeDocumentPage(noteId: note.noteId, recognizer: TaggingPageRecognizer())
    let secondWarnings = await tagging.tag(notebookId: note.notebookId, noteIds: [note.noteId])
    XCTAssertTrue(secondWarnings.isEmpty)
    let requests = await invoker.requests
    XCTAssertEqual(requests.count, 3)
    XCTAssertTrue(try service.getNote(note.noteId).tags.contains { $0.tag.name == "registered-topic" })
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "Recognized graph algorithms")
  }

  func testConfiguredPromptAndCatalogTagNotebookAndCompletedPageOnly() async throws {
    let service = try makeService()
    _ = try service.defineTag(name: "registered-topic", classId: TagClassID("topic"))
    let pending = ImportedPageMetadata(
      pageNumber: 2, ocrState: "pending", analysis: DocumentPageAnalysis(),
      originFileId: "file-test", pendingBodySHA256: nil
    )
    let metadata = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(pending))
    let ingest = try service.createNotebookWithNotes(
      title: "Imported document", kindTagName: NoteStoreSchema.importedMaterialNotebookKindTag,
      pages: [
        NotePageDraft(bodyMarkdown: "Graph algorithms"),
        NotePageDraft(bodyMarkdown: "", metaJSON: try JSONValue.object(["documentPage": metadata]).encodedString())
      ], notebookReadOnly: true
    )
    let invoker = DocumentTagInvoker()
    let tagging = DocumentAutoTagging(
      service: service,
      configuration: KaibaAIConfiguration(autoTag: KaibaAutoTagConfiguration(auto: .on, prompt: "Reuse registered-topic.")),
      invoker: invoker
    )
    let warnings = await tagging.tag(notebookId: ingest.notebook.notebookId, noteIds: ingest.notes.map(\.noteId))
    XCTAssertTrue(warnings.isEmpty)
    let requests = await invoker.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.allSatisfy { $0.systemPrompt.contains("Reuse registered-topic.") })
    XCTAssertTrue(requests.allSatisfy { request in
      request.systemPrompt.split(separator: "\n").contains {
        $0.hasPrefix("Existing tags (") && $0.contains("registered-topic")
      }
    })
    XCTAssertTrue(try service.getNotebook(ingest.notebook.notebookId).tags.contains { $0.tag.name == "registered-topic" })
    XCTAssertTrue(try service.getNote(ingest.notes[0].noteId).tags.contains { $0.tag.name == "registered-topic" })
    XCTAssertTrue(try service.getNote(ingest.notes[1].noteId).tags.isEmpty)
  }

  func testDisabledDoesNotInvokeProvider() async throws {
    let service = try makeService()
    let invoker = DocumentTagInvoker()
    let tagging = DocumentAutoTagging(service: service, configuration: nil, invoker: invoker)
    let warnings = await tagging.tag(notebookId: NotebookID("missing"), noteIds: [])
    XCTAssertTrue(warnings.isEmpty)
    let requests = await invoker.requests
    XCTAssertTrue(requests.isEmpty)
  }

  func testProviderFailurePreservesContentAndReportsEveryFailedSubject() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "Retain this OCR text.")
    let tagging = DocumentAutoTagging(
      service: service, configuration: KaibaAIConfiguration(autoTag: KaibaAutoTagConfiguration(auto: .on)),
      invoker: DocumentTagInvoker(fails: true)
    )
    let warnings = await tagging.tag(notebookId: note.notebookId, noteIds: [note.noteId])
    XCTAssertEqual(warnings.count, 2)
    XCTAssertFalse(warnings.joined().contains("private provider diagnostic"))
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "Retain this OCR text.")
  }

  func testPromptConfigurationRoundTrip() throws {
    let settings = KaibaAutoTagConfiguration(auto: .on, prompt: "Classify research topics.")
    XCTAssertEqual(try JSONDecoder().decode(KaibaAutoTagConfiguration.self, from: JSONEncoder().encode(settings)), settings)
    let legacy = try JSONDecoder().decode(KaibaAutoTagConfiguration.self, from: Data(#"{"auto":"on"}"#.utf8))
    XCTAssertNil(legacy.prompt)
  }
}

private struct TaggingPageRecognizer: DocumentPageRecognizing {
  func recognize(imageURL: URL) throws -> String { "Recognized graph algorithms" }
}
