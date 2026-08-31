import Foundation

// Note tag assignment mutations, split from `NoteService.swift` by
// responsibility. Both record their changed assignments in the action log
// (`design-docs/specs/action-history-undo.md`, U10).

public extension NoteService {
  @discardableResult
  func applyTags(
    noteId: NoteID,
    tags: [NoteTagInput],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Note {
    let note = try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        _ = try requireNote(noteId, in: db)
        let previous = try ftsPayload(noteId: noteId, in: db)
        var tagDeltas: [JSONValue] = []
        for tag in tags {
          let before = try tagAssignment(noteId: noteId, tagName: tag.name, in: db)
          try applyTag(
            noteId: noteId,
            tag: tag,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
          let after = try tagAssignment(noteId: noteId, tagName: tag.name, in: db)
          if let change = noteTagAssignmentDelta(before: before, after: after) {
            tagDeltas.append(change)
          }
        }
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let updated = try requireNote(noteId, in: db)
        if !tagDeltas.isEmpty {
          try recordAction(
            NoteActionRecord(
              kind: .noteTagsApplied,
              provenance: provenance,
              entityType: .note,
              entityId: noteId.rawValue,
              notebookId: updated.notebookId,
              display: ["title": .optionalString(updated.title)],
              delta: .object(["tags": .array(tagDeltas)]),
              undoable: true
            ),
            in: db
          )
        }
        return updated
      }
    }
    // Tag assignments drive inline tag underlining, the tag detail pane, and
    // the tag catalog, so other clients need waking just like notebook tags.
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.noteTags,
      notebookId: note.notebookId
    ))
    return note
  }

  @discardableResult
  func removeTag(noteId: NoteID, tagName: String, removedBy provenance: NoteProvenance) throws -> Note {
    let result = try driver.withDatabase { database in
      try database.transaction { db -> (note: Note, removed: Bool) in
        try requireEnabledActingUser(in: db)
        let note = try requireNote(noteId, in: db)
        let existing = try tagAssignment(noteId: noteId, tagName: tagName, in: db)
        guard let existing else {
          return (note, false)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tagName)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tagName)
        }
        let previous = try ftsPayload(noteId: noteId, in: db)
        try db.execute(
          """
          DELETE FROM note_tags
          WHERE note_id = ? AND tag_id = ?
          """,
          bindings: [.id(noteId), .id(existing.tag.tagId)]
        )
        try refreshFTS(noteId: noteId, previous: previous, in: db)
        let updated = try requireNote(noteId, in: db)
        if let change = noteTagAssignmentDelta(before: existing, after: nil) {
          try recordAction(
            NoteActionRecord(
              kind: .noteTagRemoved,
              provenance: provenance,
              entityType: .note,
              entityId: noteId.rawValue,
              notebookId: updated.notebookId,
              display: ["title": .optionalString(updated.title)],
              delta: .object(["tags": .array([change])]),
              undoable: true
            ),
            in: db
          )
        }
        return (updated, true)
      }
    }
    if result.removed {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.noteTags,
        notebookId: result.note.notebookId
      ))
    }
    return result.note
  }
}
