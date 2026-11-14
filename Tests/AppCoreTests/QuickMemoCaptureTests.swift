import Foundation
@testable import AppCore
import XCTest

/// Anywhere-capture write path
/// (`design-docs/specs/note-capture-and-entity-pages.md`, C3 and C4).
///
/// Two things are under test and they are deliberately separated: that the
/// Quick Memos notebook is a kind-tag singleton with the same invariant shape
/// as the long-term-memory bootstrap, and that capture adds no mechanism of its
/// own — the outbox and the change feed must be `createNote`'s, untouched.
final class QuickMemoCaptureTests: NoteTestCase {
  // MARK: - ensureQuickMemoNotebook

  func testEnsureCreatesTheQuickMemosNotebookCarryingTheSystemKindTag() throws {
    let service = try makeQuickMemoService()

    let notebook = try service.ensureQuickMemoNotebook()

    XCTAssertEqual(notebook.title, "Quick Memos")
    XCTAssertEqual(notebook.title, NoteService.quickMemoNotebookTitle)
    XCTAssertFalse(notebook.readOnly)

    let assignment = try XCTUnwrap(
      notebook.tags.first { $0.tag.tagId == NoteStoreSchema.quickMemoNotebookKindTagId },
      "the created notebook does not carry notebook-kind:quick-memo"
    )
    XCTAssertEqual(assignment.tag.name, NoteStoreSchema.quickMemoNotebookKindTag)
    XCTAssertEqual(assignment.tag.classId, .documentKind)
    XCTAssertTrue(assignment.tag.isSystem)
    XCTAssertEqual(assignment.provenance, .system)
    XCTAssertEqual(assignment.assignedBy, "kaiba-note")
    // The store's capture target must not be detachable by an ordinary client.
    XCTAssertFalse(assignment.deletable)
  }

  func testEnsureIsIdempotentAndLeavesExactlyOneHolderOfTheKindTag() throws {
    let service = try makeQuickMemoService()

    let first = try service.ensureQuickMemoNotebook()
    let second = try service.ensureQuickMemoNotebook()
    let third = try service.ensureQuickMemoNotebook()

    XCTAssertEqual(first.notebookId, second.notebookId)
    XCTAssertEqual(second.notebookId, third.notebookId)
    XCTAssertEqual(try quickMemoHolders(of: service), [first.notebookId])
  }

  func testEnsureFailsLoudlyWhenASecondNotebookCarriesTheKindTag() throws {
    let service = try makeQuickMemoService()
    let canonical = try service.ensureQuickMemoNotebook()

    // The invariant has to be enforced by the reader, because nothing stops an
    // operator from hand-applying the kind tag to a second notebook.
    let impostor = try service.createNotebook(title: "Stray capture target")
    try service.applyNotebookTagIds(
      notebookId: impostor.notebookId,
      tagIds: [NoteStoreSchema.quickMemoNotebookKindTagId],
      provenance: .system
    )
    XCTAssertEqual(
      Set(try quickMemoHolders(of: service)),
      [canonical.notebookId, impostor.notebookId]
    )

    XCTAssertThrowsError(try service.ensureQuickMemoNotebook()) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("multiple notebooks carry notebook-kind:quick-memo")
      )
    }
  }

  func testEnsureRecreatesTheNotebookAfterItIsDeleted() throws {
    let service = try makeQuickMemoService()
    let original = try service.ensureQuickMemoNotebook()

    try service.deleteNotebook(notebookId: original.notebookId)
    XCTAssertEqual(try quickMemoHolders(of: service), [])

    let recreated = try service.ensureQuickMemoNotebook()

    XCTAssertNotEqual(recreated.notebookId, original.notebookId)
    XCTAssertEqual(recreated.title, NoteService.quickMemoNotebookTitle)
    XCTAssertEqual(try quickMemoHolders(of: service), [recreated.notebookId])
  }

  /// A capture that arrives before any notebook exists must still work, which is
  /// the whole find-or-create point: `NoteService.init` does not bootstrap this
  /// notebook the way it bootstraps long-term memory.
  func testFreshStoreHasNoQuickMemosNotebookUntilSomethingCaptures() throws {
    let service = try makeQuickMemoService()

    XCTAssertEqual(try quickMemoHolders(of: service), [])

    let note = try service.captureQuickMemo(bodyMarkdown: "first thought")

    XCTAssertEqual(try quickMemoHolders(of: service), [note.notebookId])
  }

  // MARK: - captureQuickMemo routes through createNote

  func testCaptureEnqueuesAndDispatchesTheOrdinaryNoteCreatedAutoAction() async throws {
    let dispatcher = RecordingQuickMemoDispatcher()
    let service = try makeQuickMemoService(autoActionDispatcher: dispatcher)

    let note = try service.captureQuickMemo(bodyMarkdown: "# Idea\nShip the thing")
    await service.drainAutoActionDispatches()

    // Nothing capture-specific: this is the seeded note-created action the CLI
    // and GraphQL writes get, reaching the captured note unchanged (C4).
    let records = dispatcher.records()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.action.actionId, AutoActionID("default-ai-tagging-note-created"))
    XCTAssertEqual(records.first?.event.trigger, .noteCreated)
    XCTAssertEqual(records.first?.event.noteId, note.noteId)
    XCTAssertEqual(records.first?.event.notebookId, note.notebookId)
    XCTAssertEqual(records.first?.event.noteBodyMarkdown, "# Idea\nShip the thing")

    let attempts = try service.listAutoActionDispatchAttempts()
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.status, .dispatched)
  }

  func testCapturePublishesNotebookCreatedOnceThenNoteCreatedPerCapture() throws {
    let observer = RecordingQuickMemoObserver()
    let service = try makeQuickMemoService(changeObserver: observer)

    let first = try service.captureQuickMemo(bodyMarkdown: "one")
    XCTAssertEqual(observer.events.map(\.kind), [
      NoteChangeEventKind.notebookCreated,
      NoteChangeEventKind.noteCreated
    ])
    XCTAssertEqual(observer.events.map(\.notebookId), [first.notebookId, first.notebookId])

    let second = try service.captureQuickMemo(bodyMarkdown: "two")

    // The notebook is announced exactly once, by the run that created it; every
    // later capture is an ordinary note-created event on the same notebook, so
    // an open viewer refreshes without a capture-specific feed message.
    XCTAssertEqual(observer.events.map(\.kind), [
      NoteChangeEventKind.notebookCreated,
      NoteChangeEventKind.noteCreated,
      NoteChangeEventKind.noteCreated
    ])
    XCTAssertEqual(second.notebookId, first.notebookId)
  }

  func testCapturesAccumulateInOneNotebookInArrivalOrder() throws {
    let service = try makeQuickMemoService()

    let first = try service.captureQuickMemo(bodyMarkdown: "milk")
    let second = try service.captureQuickMemo(bodyMarkdown: "eggs")
    let third = try service.captureQuickMemo(bodyMarkdown: "bread")

    XCTAssertEqual(Set([first, second, third].map(\.notebookId)), [first.notebookId])
    XCTAssertEqual([first, second, third].map(\.noteNumber), [1, 2, 3])
    XCTAssertEqual(
      try service.listNotes(notebookId: first.notebookId).map(\.bodyMarkdown),
      ["milk", "eggs", "bread"]
    )
    XCTAssertEqual(try quickMemoHolders(of: service), [first.notebookId])
  }

  func testCaptureDerivesTitleFromBodyAndHonoursAnExplicitOne() throws {
    let service = try makeQuickMemoService()

    let derived = try service.captureQuickMemo(bodyMarkdown: "# Groceries\nmilk")
    let explicit = try service.captureQuickMemo(
      bodyMarkdown: "call the dentist",
      title: "Errand"
    )
    // A textarea that posts an empty title field must not persist an empty
    // heading; it falls back to the derived title.
    let blankTitle = try service.captureQuickMemo(
      bodyMarkdown: "# Reading\nthe long paper",
      title: "   "
    )

    XCTAssertEqual(derived.title, "Groceries")
    XCTAssertEqual(explicit.title, "Errand")
    XCTAssertEqual(blankTitle.title, "Reading")
  }

  func testCaptureStoresTheBodyVerbatim() throws {
    let service = try makeQuickMemoService()

    let note = try service.captureQuickMemo(bodyMarkdown: "  indented thought\n\nwith a gap\n")

    XCTAssertEqual(
      try service.getNote(note.noteId).bodyMarkdown,
      "  indented thought\n\nwith a gap\n"
    )
  }

  func testCaptureRejectsABlankBodyWithoutCreatingTheNotebook() throws {
    let service = try makeQuickMemoService()

    for blank in ["", "   ", "\n\t \n"] {
      XCTAssertThrowsError(try service.captureQuickMemo(bodyMarkdown: blank)) { error in
        XCTAssertEqual(
          error as? NoteServiceError,
          .invalidInput("quick memo body must not be empty"),
          "body \(String(reflecting: blank)) was not rejected"
        )
      }
    }
    // The guard runs before `ensureQuickMemoNotebook`, so a rejected capture
    // leaves no notebook behind on an otherwise untouched store.
    XCTAssertEqual(try quickMemoHolders(of: service), [])
  }

  // MARK: - Scoped principals

  func testCaptureAsAScopedPrincipalOwnsTheNotebookAndReusesIt() throws {
    let service = try makeQuickMemoService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)

    let first = try aliceService.captureQuickMemo(bodyMarkdown: "alice one")
    let second = try aliceService.captureQuickMemo(bodyMarkdown: "alice two")

    XCTAssertEqual(first.notebookId, second.notebookId)
    let notebook = try aliceService.ensureQuickMemoNotebook()
    XCTAssertEqual(notebook.notebookId, first.notebookId)
    XCTAssertEqual(notebook.ownerUserId, alice.userId)
  }

  /// Observed behaviour, recorded rather than asserted as desirable: C3 makes
  /// the Quick Memos notebook a *store-wide* kind-tag singleton, while notebook
  /// reach is per-account (`requireNotebookOwnership`,
  /// `Sources/AppCore/NoteService+LibraryEnforcement.swift:138`). A second
  /// account therefore cannot capture at all once the first account owns the
  /// singleton: the kind-tag lookup finds Alice's notebook and the ownership
  /// guard refuses it. Single-account stores — the `kaiba client issue` default,
  /// where every client is bound to the default user — never reach this. Routed
  /// forward for a design decision (per-account singleton vs. store-wide).
  func testASecondAccountCannotCaptureIntoAnotherAccountsQuickMemosNotebook() throws {
    let service = try makeQuickMemoService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceNotebook = try service.scoped(to: alice.userId).ensureQuickMemoNotebook()

    XCTAssertThrowsError(try service.scoped(to: bob.userId).captureQuickMemo(bodyMarkdown: "bob")) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .notFound("notebook not found: \(aliceNotebook.notebookId.rawValue)")
      )
    }
  }

  // MARK: - Helpers

  private func makeQuickMemoService(
    function: String = #function,
    autoActionDispatcher: AutoActionDispatching? = nil,
    changeObserver: (any NoteChangeObserving)? = nil
  ) throws -> NoteService {
    let service = try NoteService(
      driver: try makeNoteDriver(function: function),
      autoActionDispatcher: autoActionDispatcher,
      changeObserver: changeObserver
    )
    // Kaiba seeds the AI-tagging actions disabled; the shared helper opts the
    // note-created seed back in, which is exactly the action C4 relies on.
    try enableSeededAutoActions(driver: service.driver)
    return service
  }

  /// Notebook ids carrying `notebook-kind:quick-memo`, read straight from
  /// `notebook_tags` so the assertion does not depend on the code under test.
  private func quickMemoHolders(of service: NoteService) throws -> [NotebookID] {
    try service.driver.withDatabase { database in
      try database.query(
        """
        SELECT notebook_id
        FROM notebook_tags
        WHERE tag_id = ?
        ORDER BY notebook_id
        """,
        bindings: [.id(NoteStoreSchema.quickMemoNotebookKindTagId)]
      ).compactMap { $0.identifier("notebook_id", as: NotebookID.self) }
    }
  }
}

private final class RecordingQuickMemoDispatcher: AutoActionDispatching, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [AutoActionDispatchRecord] = []

  func dispatch(_ record: AutoActionDispatchRecord) async throws -> AutoActionDispatchOutcome {
    // `NSLock.lock()` is unavailable from an async context, so the mutation
    // stays in a synchronous helper, as `AutoActionTests` does.
    append(record)
    return .succeeded
  }

  private func append(_ record: AutoActionDispatchRecord) {
    lock.lock()
    recorded.append(record)
    lock.unlock()
  }

  func records() -> [AutoActionDispatchRecord] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

private final class RecordingQuickMemoObserver: NoteChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [NoteChangeEvent] = []

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    lock.lock()
    recorded.append(event)
    lock.unlock()
  }

  var events: [NoteChangeEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
