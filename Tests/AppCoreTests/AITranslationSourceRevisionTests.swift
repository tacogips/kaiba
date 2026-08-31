import Foundation
@testable import AppCore
import XCTest

private final class SourceRevisionTranslationInvoker: AgentInvoking, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [AgentInvocationRequest] = []

  func invoke(_ request: AgentInvocationRequest) async throws -> AgentInvocationResult {
    lock.withLock {
      requests.append(request)
    }
    return AgentInvocationResult(markdown: "translated: \(request.turns.last?.markdown ?? "")")
  }
}

final class AITranslationSourceRevisionTests: NoteTestCase {
  func testRunRetranslatesMutationAfterActionHistoryPrunesItsRecord() async throws {
    var service = try makeService()
    _ = try service.setAppSetting(key: "history", valueJSON: "{\"maxEntries\":10}")
    let source = try service.createNotebookWithNotes(
      title: "Prunable history guide",
      pages: (0 ..< 12).map { index in
        NotePageDraft(bodyMarkdown: "# Source \(index)\nBody.", readOnly: false)
      }
    )
    let pending = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let initialSourceMarkdown = source.notes[0].bodyMarkdown
    let updatedSourceMarkdown = "# Updated after history pruning\nBody."
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.notebookId == pending.notebookId,
        output.bodyMarkdown == "translated: \(initialSourceMarkdown)"
      else {
        return
      }
      _ = try mutationService.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: updatedSourceMarkdown
      )
    }

    let invoker = SourceRevisionTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      translationNotebookId: pending.notebookId
    )

    XCTAssertEqual(NoteService.translationState(of: completed)?.status, .completed)
    XCTAssertEqual(
      invoker.requests.filter { $0.turns.last?.markdown == updatedSourceMarkdown }.count,
      1
    )
    XCTAssertEqual(invoker.requests.count, 13)
    XCTAssertFalse(
      try service.actionHistory(limit: 50).contains {
        $0.entityId == source.notes[0].noteId.rawValue && $0.kind == .noteBodyUpdated
      },
      "the source mutation must be absent from retained history before completion"
    )
    let translated = try service.listNotes(notebookId: completed.notebookId, limit: 20, offset: 0)
    XCTAssertEqual(translated.count, 12)
    XCTAssertEqual(
      translated.filter { $0.metaJSON?.contains(source.notes[0].noteId.rawValue) == true }.map(\.bodyMarkdown),
      ["translated: \(updatedSourceMarkdown)"]
    )
  }
}
