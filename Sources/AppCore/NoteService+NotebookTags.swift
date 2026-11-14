import Foundation

public extension NoteService {
  @discardableResult
  func applyNotebookTags(
    notebookId: NotebookID,
    tags: [String],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let before = try requireNotebook(notebookId, in: db)
        for tagName in tags {
          let resolved: Tag
          if let existing = try findTag(name: tagName, in: db) {
            resolved = existing
          } else {
            try ensureTag(NoteTagInput(name: tagName), in: db)
            resolved = try requireTag(name: tagName, in: db)
          }
          try applyNotebookTag(
            notebookId: notebookId,
            tagId: resolved.tagId,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        let after = try requireNotebook(notebookId, in: db)
        return (notebook: after, tagNames: affectedFolderTagNames(before: before, after: after))
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookTags,
      notebookId: notebookId,
      tagNames: result.tagNames
    ))
    return result.notebook
  }

  @discardableResult
  func applyNotebookTagIds(
    notebookId: NotebookID,
    tagIds: [TagID],
    provenance: NoteProvenance,
    assignedBy: String? = nil
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let before = try requireNotebook(notebookId, in: db)
        for tagId in orderedUnique(tagIds) {
          try applyNotebookTag(
            notebookId: notebookId,
            tagId: tagId,
            provenance: provenance,
            assignedBy: assignedBy,
            deletable: true,
            in: db
          )
        }
        let after = try requireNotebook(notebookId, in: db)
        return (notebook: after, tagNames: affectedFolderTagNames(before: before, after: after))
      }
    }
    publishChange(NoteChangeEvent(
      kind: NoteChangeEventKind.notebookTags,
      notebookId: notebookId,
      tagNames: result.tagNames
    ))
    return result.notebook
  }

  @discardableResult
  func removeNotebookTag(
    notebookId: NotebookID,
    tagName: String,
    removedBy provenance: NoteProvenance
  ) throws -> Notebook {
    let tagId = try driver.withDatabase { database in
      try requireTag(name: tagName, in: database).tagId
    }
    return try removeNotebookTagById(
      notebookId: notebookId,
      tagId: tagId,
      removedBy: provenance
    )
  }

  @discardableResult
  func removeNotebookTagById(
    notebookId: NotebookID,
    tagId: TagID,
    removedBy provenance: NoteProvenance
  ) throws -> Notebook {
    let result = try driver.withDatabase { database in
      try database.transaction { db in
        let tag = try requireTag(id: tagId, in: db)
        let existing = try notebookTagAssignment(notebookId: notebookId, tagId: tagId, in: db)
        guard let existing else {
          return (notebook: try requireNotebook(notebookId, in: db), tagNames: nil as [String]?)
        }
        guard existing.deletable else {
          throw NoteServiceError.protectedTag(tag.name)
        }
        if provenance == .ai, existing.provenance == .human {
          throw NoteServiceError.protectedTag(tag.name)
        }
        let before = try requireNotebook(notebookId, in: db)
        try db.execute(
          """
          DELETE FROM notebook_tags
          WHERE notebook_id = ? AND tag_id = ?
          """,
          bindings: [.id(notebookId), .id(existing.tag.tagId)]
        )
        let after = try requireNotebook(notebookId, in: db)
        return (notebook: after, tagNames: affectedFolderTagNames(before: before, after: after))
      }
    }
    if let tagNames = result.tagNames {
      publishChange(NoteChangeEvent(
        kind: NoteChangeEventKind.notebookTags,
        notebookId: notebookId,
        tagNames: tagNames
      ))
    }
    return result.notebook
  }
}

/// A tag change can move a notebook between filtered catalog scopes, so
/// subscribers on both the old and the new scope need waking.
func affectedFolderTagNames(before: Notebook, after: Notebook) -> [String] {
  Array(Set(folderTagNames(of: before)).union(folderTagNames(of: after))).sorted()
}

func ensureNotebookKindTag(_ tagName: String, in database: SQLiteDatabase) throws -> Tag {
  if let existing = try findNonFolderTag(name: tagName, in: database) {
    guard existing.classId == .documentKind, existing.isSystem else {
      throw NoteStoreSchemaError.systemTagCollision(name: tagName)
    }
    return existing
  }
  let tagId = notebookKindTagId(for: tagName)
  try database.execute(
    """
    INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
    VALUES (?, ?, 'document-kind', 1, ?)
    ON CONFLICT DO NOTHING
    """,
    bindings: [.id(tagId), .text(tagName), .text(NoteStoreClock.system.now())]
  )
  let tag = try requireNonFolderTag(name: tagName, in: database)
  guard tag.tagId == tagId, tag.classId == .documentKind, tag.isSystem else {
    throw NoteStoreSchemaError.systemTagCollision(name: tagName)
  }
  return tag
}

private func notebookKindTagId(for tagName: String) -> TagID {
  TagID("notebook-kind-\(tagName.utf8.map { String(format: "%02x", $0) }.joined())")
}
