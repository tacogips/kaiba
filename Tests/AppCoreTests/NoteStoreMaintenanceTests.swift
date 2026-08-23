import Foundation
@testable import AppCore
import XCTest

final class NoteStoreMaintenanceTests: NoteTestCase {
  func testCheckStoreReportsHealthyOnFreshStore() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    _ = try service.createNote(bodyMarkdown: "# Healthy note\nbody")

    let report = try service.checkStore()

    XCTAssertTrue(report.isHealthy)
    XCTAssertEqual(report.schemaVersion, NoteStoreSchema.currentVersion)
    XCTAssertEqual(report.integrityMessages, ["ok"])
    XCTAssertEqual(report.foreignKeyViolations, [])
    XCTAssertTrue(report.searchIndexHealthy)
    XCTAssertEqual(report.notesMissingFromSearchIndex, [])
    XCTAssertEqual(report.orphanedSearchIndexRows, 0)
    XCTAssertFalse(report.searchIndexRepaired)
  }

  func testCheckStoreRepairReindexesNoteMissingFromSearch() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let note = try service.createNote(bodyMarkdown: "# Vanished\nsearchable body text")
    try driver.withDatabase { database in
      try database.execute(
        "DELETE FROM note_fts_map WHERE note_id = ?",
        bindings: [.id(note.noteId)]
      )
    }
    // The LIKE fallback still surfaces the note, so search alone cannot
    // reveal the drift — which is exactly why the check exists.
    let damaged = try service.checkStore()
    XCTAssertFalse(damaged.isHealthy)
    XCTAssertEqual(damaged.notesMissingFromSearchIndex, [note.noteId])

    let repaired = try service.checkStore(repair: true)
    XCTAssertTrue(repaired.searchIndexRepaired)
    XCTAssertTrue(repaired.isHealthy)
    try driver.withDatabase { database in
      XCTAssertEqual(
        try database.query(
          "SELECT COUNT(*) AS total FROM note_fts_map WHERE note_id = ?",
          bindings: [.id(note.noteId)]
        ).first?["total"],
        "1"
      )
    }
    XCTAssertEqual(
      try service.searchNotes(query: "searchable body").map(\.note.noteId),
      [note.noteId]
    )
  }

  func testCheckStoreDetectsAndRepairsOrphanedSearchIndexRows() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let kept = try service.createNote(bodyMarkdown: "# Kept\nremains searchable")
    let doomed = try service.createNote(bodyMarkdown: "# Doomed\nabout to vanish")
    // Simulate a buggy or interrupted deletion: the note row disappears while
    // its search-index row survives. Foreign keys must be off for the bad
    // delete to land, and are restored before the connection is reused.
    try driver.withDatabase { database in
      try database.execute("PRAGMA foreign_keys=OFF")
      defer {
        try? database.execute("PRAGMA foreign_keys=ON")
      }
      try database.execute(
        "DELETE FROM notes WHERE note_id = ?",
        bindings: [.id(doomed.noteId)]
      )
    }

    let damaged = try service.checkStore()
    XCTAssertFalse(damaged.isHealthy)
    XCTAssertEqual(damaged.orphanedSearchIndexRows, 1)
    XCTAssertFalse(damaged.foreignKeyViolations.isEmpty)

    let repaired = try service.checkStore(repair: true)
    XCTAssertTrue(repaired.searchIndexRepaired)
    XCTAssertEqual(repaired.orphanedSearchIndexRows, 0)
    XCTAssertEqual(repaired.foreignKeyViolations, [])
    XCTAssertTrue(repaired.isHealthy)
    XCTAssertEqual(
      try service.searchNotes(query: "remains searchable").map(\.note.noteId),
      [kept.noteId]
    )
  }

  func testOptimizeStoreVacuumCompactsAfterDeletes() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let filler = String(repeating: "compactable payload ", count: 2_000)
    let noteIds = try (0..<20).map { index in
      try service.createNote(bodyMarkdown: "# Filler \(index)\n\(filler)").noteId
    }
    for noteId in noteIds {
      try service.deleteNote(noteId: noteId)
    }

    let report = try service.optimizeStore(vacuum: true)

    XCTAssertTrue(report.vacuumed)
    XCTAssertLessThan(report.bytesAfter, report.bytesBefore)
    XCTAssertEqual(report.freelistPagesAfter, 0)
  }

  func testCheckStoreRequiresAdministratorForAuthenticatedCallers() throws {
    let driver = try makeNoteDriver()
    let service = try NoteService(driver: driver)
    let member = try service.createUser(email: "member@example.com", displayName: "Member")
    let scoped = service.scoped(to: member.userId)

    XCTAssertThrowsError(try scoped.checkStore())
    XCTAssertThrowsError(try scoped.optimizeStore())
  }
}
