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
    let pending = try service.startTranslationJob(
      notebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    let initialSourceMarkdown = source.notes[0].bodyMarkdown
    let updatedSourceMarkdown = "# Updated after history pruning\nBody."
    let mutationService = service
    service.translationOutputPostCommitHook = { output in
      guard output.noteId == source.notes[0].noteId,
        output.body == "translated: \(initialSourceMarkdown)"
      else {
        return
      }
      _ = try mutationService.updateNoteBody(
        noteId: source.notes[0].noteId,
        bodyMarkdown: updatedSourceMarkdown
      )
      // Translations record no history, so unrelated writes push the source
      // edit out of the 10-entry retention window before completion.
      let scratch = try mutationService.createNotebook(title: "Unrelated writes")
      for index in 0 ..< 12 {
        _ = try mutationService.createNote(notebookId: scratch.notebookId, bodyMarkdown: "Unrelated \(index)")
      }
    }

    let invoker = SourceRevisionTranslationInvoker()
    let completed = try await AITranslationService(service: service, invoker: invoker).run(
      jobId: pending.jobId
    )

    XCTAssertEqual(completed.status, .completed)
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
    XCTAssertEqual(
      try source.notes.map { try service.noteTranslations(noteId: $0.noteId).count },
      Array(repeating: 1, count: 12)
    )
    XCTAssertEqual(
      try service.noteTranslations(noteId: source.notes[0].noteId).map(\.body),
      ["translated: \(updatedSourceMarkdown)"]
    )
  }
}
