import Foundation
@testable import AppCore
import XCTest

final class NoteServiceMemoKindTagTests: NoteTestCase {
  func testImplicitNotebookCreationAppliesSystemNonDeletableKindTag() throws {
    let service = try makeService()

    let note = try service.createNote(
      notebookTitle: "User Memo",
      notebookKindTagName: "notebook-kind:user-memo",
      bodyMarkdown: "# Memo\nBody"
    )

    let notebook = try service.getNotebook(note.notebookId)
    let kindTag = notebook.tags.first { $0.tag.name == "notebook-kind:user-memo" }
    XCTAssertNotNil(kindTag, "expected the auto-created notebook to carry the memo kind tag")
    XCTAssertEqual(kindTag?.provenance, .system)
    XCTAssertFalse(kindTag?.deletable ?? true, "the kind tag must be non-deletable")
  }

  func testKindTagIsProtectedFromRemoval() throws {
    let service = try makeService()
    let note = try service.createNote(
      notebookTitle: "User Memo",
      notebookKindTagName: "notebook-kind:user-memo",
      bodyMarkdown: "# Memo\nBody"
    )

    XCTAssertThrowsError(
      try service.removeNotebookTag(
        notebookId: note.notebookId,
        tagName: "notebook-kind:user-memo",
        removedBy: .human
      )
    ) { error in
      guard case NoteServiceError.protectedTag = error else {
        return XCTFail("expected protectedTag, got \(error)")
      }
    }
  }

  func testMemoNotebooksMatchKindTagFilter() throws {
    let service = try makeService()
    _ = try service.createNote(bodyMarkdown: "# Plain\nBody")
    let memo = try service.createNote(
      notebookTitle: "User Memo",
      notebookKindTagName: "notebook-kind:user-memo",
      bodyMarkdown: "# Memo\nBody"
    )

    let filtered = try service.listNotebooks(tagFilter: ["notebook-kind:user-memo"])

    XCTAssertEqual(filtered.map(\.notebookId), [memo.notebookId])
  }

  func testMemoNotebookCreationTriggersKindFilteredAutoAction() async throws {
    let dispatcher = RecordingMemoAutoActionDispatcher()
    let service = try makeService(autoActionDispatcher: dispatcher)
    _ = try service.configureAutoAction(
      actionId: "memo-kind",
      trigger: .notebookCreated,
      workflowId: "memo-workflow",
      filterJSON: #"{"notebookKindTag":"notebook-kind:user-memo"}"#
    )

    _ = try service.createNote(bodyMarkdown: "# Plain\nBody")
    let memo = try service.createNote(
      notebookTitle: "User Memo",
      notebookKindTagName: "notebook-kind:user-memo",
      bodyMarkdown: "# Memo\nBody"
    )
    await service.drainAutoActionDispatches()

    // The kind-filtered notebook-created action fires exactly once, only for the
    // memo notebook — the earlier plain notebook is filtered out.
    let memoKindDispatches = dispatcher.records().filter { $0.action.actionId == "memo-kind" }
    XCTAssertEqual(memoKindDispatches.map(\.event.notebookId), [memo.notebookId])
  }

  private func makeService(
    function: String = #function,
    autoActionDispatcher: AutoActionDispatching? = nil
  ) throws -> NoteService {
    try NoteService(
      driver: try makeNoteDriver(function: function),
      autoActionDispatcher: autoActionDispatcher
    )
  }
}

private final class RecordingMemoAutoActionDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    append(record)
    return .succeeded
  }

  private func append(_ record: AutoActionDispatchRecord) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(record)
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
