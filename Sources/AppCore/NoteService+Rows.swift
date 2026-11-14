import Foundation

func noteTags(noteId: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.parent_tag_id, t.status_set_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ?
      ORDER BY t.name, ifnull(t.parent_tag_id, ''), t.tag_id
      """,
    id: noteId,
    in: database
  )
}

func noteTags(noteIds: [String], in database: SQLiteDatabase) throws -> [String: [TagAssignment]] {
  let orderedNoteIds = orderedUnique(noteIds)
  guard !orderedNoteIds.isEmpty else {
    return [:]
  }
  let rows = try database.query(
    """
      SELECT nt.note_id, t.tag_id, t.name, t.class_id, t.parent_tag_id, t.status_set_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id IN (\(placeholders(count: orderedNoteIds.count)))
      ORDER BY nt.note_id, t.name, ifnull(t.parent_tag_id, ''), t.tag_id
      """,
    bindings: orderedNoteIds.map(SQLiteValue.text)
  )
  var tagsByNoteId: [String: [TagAssignment]] = [:]
  tagsByNoteId.reserveCapacity(orderedNoteIds.count)
  for row in rows {
    guard let noteId = row["note_id"] else {
      throw NoteServiceError.invalidRow("tag assignment row is missing note_id")
    }
    tagsByNoteId[noteId, default: []].append(try tagAssignment(from: row))
  }
  return tagsByNoteId
}

func notebookTags(notebookId: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.parent_tag_id, t.status_set_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM notebook_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.notebook_id = ?
      ORDER BY t.name, ifnull(t.parent_tag_id, ''), t.tag_id
      """,
    id: notebookId,
    in: database
  )
}

func tagAssignment(noteId: String, tagName: String, in database: SQLiteDatabase) throws -> TagAssignment? {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.parent_tag_id, t.status_set_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM note_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.note_id = ? AND t.name = ?
        AND (t.class_id IS NULL OR t.class_id <> 'folder')
      """,
    bindings: [.text(noteId), .text(tagName)],
    in: database
  ).first
}

func notebookTagAssignment(notebookId: String, tagName: String, in database: SQLiteDatabase) throws -> TagAssignment? {
  guard let tag = try findTag(name: tagName, in: database) else { return nil }
  return try notebookTagAssignment(notebookId: notebookId, tagId: tag.tagId, in: database)
}

func notebookTagAssignment(notebookId: String, tagId: String, in database: SQLiteDatabase) throws -> TagAssignment? {
  try tagAssignments(
    sql: """
      SELECT t.tag_id, t.name, t.class_id, t.parent_tag_id, t.status_set_id, t.is_system, t.created_at,
        nt.provenance, nt.assigned_by, nt.deletable, nt.created_at AS assigned_at
      FROM notebook_tags nt
      INNER JOIN tags t ON t.tag_id = nt.tag_id
      WHERE nt.notebook_id = ? AND t.tag_id = ?
      """,
    bindings: [.text(notebookId), .text(tagId)],
    in: database
  ).first
}

private func tagAssignments(sql: String, id: String, in database: SQLiteDatabase) throws -> [TagAssignment] {
  try tagAssignments(sql: sql, bindings: [.text(id)], in: database)
}

private func tagAssignments(sql: String, bindings: [SQLiteValue], in database: SQLiteDatabase) throws -> [TagAssignment] {
  try database.query(sql, bindings: bindings).map(tagAssignment(from:))
}

private func tagAssignment(from row: SQLiteRow) throws -> TagAssignment {
  guard let provenanceText = row["provenance"],
        let provenance = NoteProvenance(rawValue: provenanceText),
        let assignedAt = row["assigned_at"] else {
    throw NoteServiceError.invalidRow("tag assignment row is missing required fields")
  }
  return TagAssignment(
    tag: try tag(from: row),
    provenance: provenance,
    assignedBy: row["assigned_by"] ?? nil,
    deletable: row["deletable"] != "0",
    createdAt: assignedAt
  )
}

func orderedUnique(_ values: [String]) -> [String] {
  var seen = Set<String>()
  return values.filter { seen.insert($0).inserted }
}

func firstNotePreview(notebookId: String, in database: SQLiteDatabase) throws -> String? {
  let rows = try database.query(
    """
    SELECT body_markdown
    FROM notes
    WHERE notebook_id = ?
    ORDER BY note_number
    LIMIT 1
    """,
    bindings: [.text(notebookId)]
  )
  guard let body = rows.first?["body_markdown"] else {
    return nil
  }
  return notebookPreviewText(body)
}

func nextNoteNumber(notebookId: String, in database: SQLiteDatabase) throws -> Int {
  let rows = try database.query(
    "SELECT ifnull(max(note_number), 0) + 1 AS next_note_number FROM notes WHERE notebook_id = ?",
    bindings: [.text(notebookId)]
  )
  return Int(rows.first?["next_note_number"] ?? "") ?? 1
}

func validateNotebookIngestPageNumbers(_ pages: [NotePageDraft]) throws {
  // The effective number of each page is its explicit `noteNumber` or, when
  // absent, its 1-based position (matching `insertNotebookWithNotes`). A mix of
  // explicit and positional numbers can collide (e.g. page 1 positional == an
  // explicit `1` elsewhere), which would otherwise surface as an opaque UNIQUE
  // constraint error. Compute every effective number and reject collisions,
  // naming the colliding page positions.
  var numberToPageIndex: [Int: Int] = [:]
  for (index, page) in pages.enumerated() {
    let effectiveNumber = page.noteNumber ?? index + 1
    guard effectiveNumber > 0 else {
      throw NoteServiceError.invalidInput(
        "notebook ingest page \(index + 1) has a non-positive note number \(effectiveNumber)"
      )
    }
    if let existingIndex = numberToPageIndex[effectiveNumber] {
      throw NoteServiceError.invalidInput(
        "notebook ingest pages \(existingIndex + 1) and \(index + 1) collide on note number \(effectiveNumber)"
      )
    }
    numberToPageIndex[effectiveNumber] = index
  }
}

func noteTitle(from bodyMarkdown: String) -> String? {
  NoteTitleDerivation.title(from: bodyMarkdown)
}

/// How a note's stored title was produced. A `.derived` title is re-computed
/// from the body on every `updateNoteBody`; an `.explicit` title (supplied via
/// the `title:` argument on create) is preserved across body edits.
enum NoteTitleSource: String, Sendable {
  case derived
  case explicit
}

func noteTitleSource(noteId: String, in database: SQLiteDatabase) throws -> NoteTitleSource {
  let rows = try database.query(
    "SELECT title_source FROM notes WHERE note_id = ? LIMIT 1",
    bindings: [.text(noteId)]
  )
  guard let raw = rows.first?["title_source"], let source = NoteTitleSource(rawValue: raw) else {
    return .derived
  }
  return source
}

func makeNoteId(prefix: String) -> String {
  let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
  return "\(prefix)-\(milliseconds)-\(UUID().uuidString.lowercased())"
}
