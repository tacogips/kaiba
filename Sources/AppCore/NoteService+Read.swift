import Foundation

public extension NoteService {
  func getNotebook(_ notebookId: NotebookID) throws -> Notebook {
    try driver.withDatabase { database in
      try requireNotebook(notebookId, in: database)
    }
  }

  func getNote(_ noteId: NoteID) throws -> Note {
    try driver.withDatabase { database in
      try requireNote(noteId, in: database)
    }
  }
}
