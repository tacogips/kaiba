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

  /// C3 delta: the singleton is per write principal, so two accounts capture
  /// side by side. Each finds or creates its own Quick Memos notebook, sees
  /// only its own captures, and neither errors on the other's — the shape the
  /// per-user bearer credential already implies, with no operator-service
  /// bypass. The pre-delta store-wide lookup made the first capturing account
  /// the sole owner and failed every other account's capture forever.
  func testEachAccountCapturesIntoItsOwnQuickMemosNotebook() throws {
    let service = try makeQuickMemoService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)

    let aliceNote = try aliceService.captureQuickMemo(bodyMarkdown: "alice thought")
    // Bob captures second, with Alice's holder already in the store: under the
    // store-wide lookup this is the call that used to throw.
    let bobNote = try bobService.captureQuickMemo(bodyMarkdown: "bob thought")

    XCTAssertNotEqual(aliceNote.notebookId, bobNote.notebookId)
    XCTAssertEqual(
      try aliceService.ensureQuickMemoNotebook().notebookId,
      aliceNote.notebookId
    )
    XCTAssertEqual(
      try bobService.ensureQuickMemoNotebook().notebookId,
      bobNote.notebookId
    )
    XCTAssertEqual(
      try quickMemoHolders(of: service, ownedBy: alice.userId),
      [aliceNote.notebookId]
    )
    XCTAssertEqual(
      try quickMemoHolders(of: service, ownedBy: bob.userId),
      [bobNote.notebookId]
    )

    // Each notebook holds only its owner's captures, and neither account can
    // read the other's through the id it never learns.
    XCTAssertEqual(
      try aliceService.listNotes(notebookId: aliceNote.notebookId).map(\.bodyMarkdown),
      ["alice thought"]
    )
    XCTAssertEqual(
      try bobService.listNotes(notebookId: bobNote.notebookId).map(\.bodyMarkdown),
      ["bob thought"]
    )
    XCTAssertThrowsError(try aliceService.listNotes(notebookId: bobNote.notebookId)) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .notFound("notebook not found: \(bobNote.notebookId.rawValue)")
      )
    }
    XCTAssertFalse(
      try aliceService.listNotebooks().map(\.notebookId).contains(bobNote.notebookId)
    )
    // Negative control on the owner predicate: store-wide the kind tag now has
    // two holders. That is exactly the set the pre-delta lookup read, and why
    // it handed Bob Alice's notebook for `requireNotebook` to refuse.
    XCTAssertEqual(
      Set(try quickMemoHolders(of: service)),
      [aliceNote.notebookId, bobNote.notebookId]
    )
  }

  /// The scope is `(owner_user_id, library_id)`, not the owner alone. One
  /// account working in two libraries gets one Quick Memos notebook in each;
  /// an owner-only filter would hand the second library's capture the first
  /// library's notebook, which `requireNotebook` then refuses for library
  /// reach — the cross-library form of the leak the C3 delta closes.
  func testTheSameAccountGetsItsOwnQuickMemosNotebookPerLibrary() throws {
    let service = try makeQuickMemoService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let aliceService = service.scoped(to: alice.userId)
    let second = try aliceService.createLibrary(name: "Second", title: "Second")
    let secondScope = aliceService.scoped(toLibrary: second.libraryId)

    let inDefault = try aliceService.captureQuickMemo(bodyMarkdown: "default library")
    let inSecond = try secondScope.captureQuickMemo(bodyMarkdown: "second library")

    XCTAssertNotEqual(inDefault.notebookId, inSecond.notebookId)
    // Stable on the next call in each scope: neither sees two holders.
    XCTAssertEqual(
      try aliceService.ensureQuickMemoNotebook().notebookId,
      inDefault.notebookId
    )
    XCTAssertEqual(
      try secondScope.ensureQuickMemoNotebook().notebookId,
      inSecond.notebookId
    )
    XCTAssertEqual(
      try libraryId(ofNotebook: inSecond.notebookId, service: service),
      second.libraryId
    )
    // Negative control on the library predicate: filtering by owner alone
    // matches both notebooks, so an owner-only lookup would report two holders
    // to whichever library scope asked next.
    XCTAssertEqual(
      Set(try quickMemoHolders(of: service, ownedBy: alice.userId, inLibrary: nil)),
      [inDefault.notebookId, inSecond.notebookId]
    )
  }

  /// The multi-holder invariant is evaluated within the caller's scope only: a
  /// second holder inside one account's scope is still a loud failure, and a
  /// different account's holder is not part of that count.
  func testTheSingletonInvariantIsScopedToTheCapturingPrincipal() throws {
    let service = try makeQuickMemoService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try service.createUser(email: "bob@example.com", displayName: "Bob")
    let aliceService = service.scoped(to: alice.userId)
    let bobService = service.scoped(to: bob.userId)

    let aliceNotebook = try aliceService.ensureQuickMemoNotebook()
    let bobNotebook = try bobService.ensureQuickMemoNotebook()

    // Nothing stops an operator from hand-applying the kind tag to a second
    // notebook of Alice's; that, and only that, trips Alice's invariant.
    let impostor = try aliceService.createNotebook(title: "Stray capture target")
    try aliceService.applyNotebookTagIds(
      notebookId: impostor.notebookId,
      tagIds: [NoteStoreSchema.quickMemoNotebookKindTagId],
      provenance: .system
    )
    XCTAssertEqual(
      Set(try quickMemoHolders(of: service, ownedBy: alice.userId)),
      [aliceNotebook.notebookId, impostor.notebookId]
    )

    XCTAssertThrowsError(try aliceService.ensureQuickMemoNotebook()) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .invalidInput("multiple notebooks carry notebook-kind:quick-memo")
      )
    }
    // Bob is untouched by a defect in Alice's scope: three holders exist in the
    // store and his capture still resolves to exactly his own notebook.
    XCTAssertEqual(try bobService.ensureQuickMemoNotebook().notebookId, bobNotebook.notebookId)
    XCTAssertEqual(
      try bobService.captureQuickMemo(bodyMarkdown: "bob unaffected").notebookId,
      bobNotebook.notebookId
    )
  }

  /// Edge case from the design: two concurrent first captures by the same
  /// principal. `ensureQuickMemoNotebook` is one serialized transaction, so
  /// they converge on one notebook with exactly one `notebookCreated` event
  /// and no second holder left behind.
  func testConcurrentFirstCapturesConvergeOnOneNotebookAndOneCreationEvent() throws {
    let observer = RecordingQuickMemoObserver()
    let service = try makeQuickMemoService(changeObserver: observer)
    let results = ConcurrentQuickMemoResults()

    DispatchQueue.concurrentPerform(iterations: 12) { index in
      do {
        results.record(notebookId: try service.captureQuickMemo(bodyMarkdown: "thought \(index)").notebookId)
      } catch {
        results.record(error: error)
      }
    }

    XCTAssertTrue(results.errors.isEmpty, results.errors.joined(separator: "\n"))
    XCTAssertEqual(results.notebookIds.count, 12)
    XCTAssertEqual(Set(results.notebookIds).count, 1)
    let notebookId = try XCTUnwrap(results.notebookIds.first)
    XCTAssertEqual(try quickMemoHolders(of: service), [notebookId])
    XCTAssertEqual(
      observer.events.filter { $0.kind == NoteChangeEventKind.notebookCreated }.count,
      1
    )
    XCTAssertEqual(
      observer.events.filter { $0.kind == NoteChangeEventKind.noteCreated }.count,
      12
    )
    XCTAssertEqual(try service.listNotes(notebookId: notebookId).count, 12)
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

  /// The same read narrowed to one owner, and by default to one library --
  /// the scope `quickMemoNotebookIds` is supposed to apply. Written out here
  /// rather than delegating, so the assertion stays independent of the code
  /// under test. Passing `inLibrary: nil` drops the library predicate, which
  /// is how a test reads the owner-only set the C3 delta rejects.
  private func quickMemoHolders(
    of service: NoteService,
    ownedBy ownerUserId: UserID,
    inLibrary libraryId: LibraryID? = NoteStoreSchema.defaultLibraryId
  ) throws -> [NotebookID] {
    var sql = """
      SELECT notebook_tags.notebook_id AS notebook_id
      FROM notebook_tags
      JOIN notebooks ON notebooks.notebook_id = notebook_tags.notebook_id
      WHERE notebook_tags.tag_id = ?
      AND notebooks.owner_user_id = ?
      """
    var bindings: [SQLiteValue] = [
      .id(NoteStoreSchema.quickMemoNotebookKindTagId),
      .id(ownerUserId)
    ]
    if let libraryId {
      sql += "\nAND notebooks.library_id = ?"
      bindings.append(.id(libraryId))
    }
    sql += "\nORDER BY notebook_tags.notebook_id"
    return try service.driver.withDatabase { database in
      try database.query(sql, bindings: bindings)
        .compactMap { $0.identifier("notebook_id", as: NotebookID.self) }
    }
  }

  private func libraryId(
    ofNotebook notebookId: NotebookID,
    service: NoteService
  ) throws -> LibraryID {
    try service.driver.withDatabase { database in
      let rows = try database.query(
        "SELECT library_id FROM notebooks WHERE notebook_id = ?",
        bindings: [.id(notebookId)]
      )
      return try XCTUnwrap(rows.first?.identifier("library_id", as: LibraryID.self))
    }
  }
}

/// Collects results off the concurrent workers, as `NoteServiceTests` does for
/// its own concurrency case.
private final class ConcurrentQuickMemoResults: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedNotebookIds: [NotebookID] = []
  private var recordedErrors: [String] = []

  func record(notebookId: NotebookID) {
    lock.lock()
    recordedNotebookIds.append(notebookId)
    lock.unlock()
  }

  func record(error: Error) {
    lock.lock()
    recordedErrors.append(String(describing: error))
    lock.unlock()
  }

  var notebookIds: [NotebookID] {
    lock.lock()
    defer { lock.unlock() }
    return recordedNotebookIds
  }

  var errors: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedErrors
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
