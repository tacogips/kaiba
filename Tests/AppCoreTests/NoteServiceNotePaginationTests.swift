import AppCore
import XCTest

final class NoteServiceNotePaginationTests: NoteTestCase {
  func testNoteOffsetUsesStableNotebookOrderWithoutLoadingPrecedingNotes() throws {
    let service = try makeService()
    let ingest = try service.createNotebookWithNotes(
      title: "Windowed",
      pages: [10, 30, 20, 40].map { noteNumber in
        NotePageDraft(bodyMarkdown: "# Page \(noteNumber)", noteNumber: noteNumber)
      }
    )

    let notes = try service.listNotes(notebookId: ingest.notebook.notebookId)

    XCTAssertEqual(notes.map(\.noteNumber), [10, 20, 30, 40])
    XCTAssertEqual(try notes.map { try service.noteOffsetInNotebook(noteId: $0.noteId) }, [0, 1, 2, 3])
  }
}
