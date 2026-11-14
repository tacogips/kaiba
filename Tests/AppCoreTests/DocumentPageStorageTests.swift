import Foundation
@testable import AppCore
import XCTest

/// `document_pages` as a storage reference and as a CLI-visible field
/// (`design-docs/specs/note-store-schema-v25.md`).
final class DocumentPageStorageTests: NoteTestCase {
  func testStorageGCKeepsFilesReferencedOnlyByDocumentPages() throws {
    let root = try makeNoteRoot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    let origin = try insertSyntheticOriginFile(service)
    let unreferenced = try insertSyntheticOriginFile(service)
    _ = try service.createNotebookWithNotes(
      title: "Pages", pages: [syntheticPageDraft(originFileId: origin, text: "kept")]
    )

    let result = try service.reclaimUnreferencedFiles(olderThan: 0)

    XCTAssertEqual(result.deletedFileIds, [unreferenced])
    XCTAssertNoThrow(try service.getFileRecord(fileId: origin))
    XCTAssertEqual(try service.checkStore().unreferencedFiles, 0)
  }

  func testCLIShowIncludesDocumentPageAndTranslationsListsVersions() throws {
    let root = try makeNoteRoot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))
    let page = try service.createNotebookWithNotes(
      title: "Pages",
      pages: [syntheticPageDraft(pageNumber: 3, originFileId: try insertSyntheticOriginFile(service), text: "Harbor")]
    ).notes[0]
    try service.driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO note_translations (note_id, language, body, source_sha256, provenance, created_at, updated_at)
        VALUES (?, 'ja', 'Minato', ?, 'ai', 'now', 'now')
        """,
        bindings: [.id(page.noteId), .text(NoteService.translationSourceContentHash("Harbor"))]
      )
    }

    let shown = try JSONValue(parsing: try AppCommand(
      arguments: ["--note-root", root, "show", page.noteId.rawValue, "--output", "json"], environment: [:]
    ).run())
    let documentPage = try XCTUnwrap(shown["documentPage"]?.asObject)
    XCTAssertEqual(documentPage["pageNumber"], .integer(3))
    XCTAssertEqual(documentPage["textStatus"], .string("complete"))
    XCTAssertEqual(documentPage["textSource"], .string("ocr"))
    XCTAssertEqual(documentPage["originMediaType"], .string("application/pdf"))

    let listed = try JSONValue(parsing: try AppCommand(
      arguments: ["--note-root", root, "translations", page.noteId.rawValue, "--output", "json"], environment: [:]
    ).run())
    let translations = try XCTUnwrap(listed["translations"]?.asArray)
    XCTAssertEqual(translations.count, 1)
    XCTAssertEqual(translations.first?["language"], .string("ja"))
    XCTAssertEqual(translations.first?["isCurrent"], .bool(true))

    let text = try AppCommand(arguments: ["--note-root", root, "translations", page.noteId.rawValue], environment: [:]).run()
    XCTAssertEqual(text, "## ja\nMinato")
  }
}
