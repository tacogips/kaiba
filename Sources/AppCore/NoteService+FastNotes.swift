import Foundation

public extension NoteService {
  /// A page of user text notes, filtered before pagination and ordered by
  /// creation rather than edits. Document pages and internal notebooks stay
  /// in their dedicated readers. Scope is identical to the cross-library feed.
  func fastNotes(query: String = "", limit: Int = 50, offset: Int = 0) throws -> [Note] {
    guard (1...200).contains(limit), offset >= 0, query.utf8.count <= 4096 else {
      throw NoteServiceError.invalidInput("invalid Fast Note query or page bounds")
    }
    return try driver.withDatabase { db in
      var predicates = [
        "NOT EXISTS (SELECT 1 FROM document_pages p WHERE p.note_id = notes.note_id)",
        """
        NOT EXISTS (SELECT 1 FROM notebook_tags nt JOIN tags t ON t.tag_id = nt.tag_id
          WHERE nt.notebook_id = notes.notebook_id
          AND t.name IN ('notebook-kind:agent-conversation', 'notebook-kind:long-term-memory', 'notebook-kind:tag-memo'))
        """
      ]
      var bindings: [SQLiteValue] = []
      appendLibraryScopePredicate(alias: "notes", reachableLibraryIds: try reachableLibraryIds(in: db), predicates: &predicates, bindings: &bindings)
      appendOwnerScopePredicate(alias: "notes", actingUserId: actingUserId, predicates: &predicates, bindings: &bindings)
      appendPendingNotebookIngestExclusionPredicate(alias: "notes", excludesPendingNotebookIngests: !allowsPendingNotebookIngestAccess, predicates: &predicates)
      for term in query.split(whereSeparator: \.isWhitespace) {
        predicates.append("instr(lower(coalesce(notes.title, '') || char(10) || notes.body_markdown || char(10) || b.title), lower(?)) > 0")
        bindings.append(.text(String(term)))
      }
      bindings += [.int(Int64(limit)), .int(Int64(offset))]
      let rows = try db.query("""
        SELECT notes.note_id, notes.notebook_id, notes.note_number, notes.title,
          notes.body_markdown, notes.read_only, notes.created_at, notes.updated_at,
          CASE WHEN notes.meta_json IS NULL THEN NULL ELSE json(notes.meta_json) END AS meta_json
        FROM notes JOIN notebooks b ON b.notebook_id = notes.notebook_id
        WHERE \(predicates.joined(separator: " AND "))
        ORDER BY notes.created_at DESC, notes.note_id DESC
        LIMIT ? OFFSET ?
        """, bindings: bindings)
      return try notes(from: rows, in: db)
    }
  }
}
