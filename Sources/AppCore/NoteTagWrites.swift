import Foundation

// Tag-write primitives shared by notebook/note mutations, split from
// `NoteService.swift` by responsibility: they create tags on demand and
// apply assignments with the provenance/deletable upgrade rules, on an
// already-open transaction.

func applyNotebookTag(
  notebookId: NotebookID,
  tagName: String,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  allowsLongTermMemoryIdentityCreation: Bool = false,
  in database: SQLiteDatabase
) throws {
  let tag: Tag
  if let existing = try findTag(name: tagName, in: database) {
    tag = existing
  } else {
    try ensureTag(NoteTagInput(name: tagName), in: database)
    tag = try requireTag(name: tagName, in: database)
  }
  try applyNotebookTag(
    notebookId: notebookId,
    tagId: tag.tagId,
    provenance: provenance,
    assignedBy: assignedBy,
    deletable: deletable,
    allowsLongTermMemoryIdentityCreation: allowsLongTermMemoryIdentityCreation,
    in: database
  )
}

func applyNotebookTag(
  notebookId: NotebookID,
  tagId: TagID,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  allowsLongTermMemoryIdentityCreation: Bool = false,
  in database: SQLiteDatabase
) throws {
  let tag = try requireTag(id: tagId, in: database)
  if tag.tagId == NoteStoreSchema.longTermMemoryNotebookKindTagId {
    try validateLongTermMemoryNotebookTagAssignment(
      notebookId: notebookId,
      allowsIdentityCreation: allowsLongTermMemoryIdentityCreation,
      in: database
    )
  }
  let existing = try notebookTagAssignment(notebookId: notebookId, tagId: tagId, in: database)
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  try database.execute(
    """
    INSERT INTO notebook_tags (
      notebook_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(notebook_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN notebook_tags.provenance = 'system' THEN notebook_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN notebook_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .id(notebookId),
      .id(tag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

func applyTag(
  noteId: NoteID,
  tag: NoteTagInput,
  provenance: NoteProvenance,
  assignedBy: String?,
  deletable: Bool,
  in database: SQLiteDatabase
) throws {
  try ensureTag(tag, in: database)
  let existing = try tagAssignment(noteId: noteId, tagName: tag.name, in: database)
  if let existing, existing.provenance == .human, provenance == .ai {
    return
  }
  if let existing, existing.provenance == .system, provenance != .system {
    return
  }
  let storedTag = try requireNonFolderTag(name: tag.name, in: database)
  try database.execute(
    """
    INSERT INTO note_tags (
      note_id, tag_id, provenance, assigned_by, deletable, created_at
    ) VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(note_id, tag_id) DO UPDATE SET
      provenance = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.provenance
        ELSE excluded.provenance
      END,
      assigned_by = CASE
        WHEN note_tags.provenance = 'system' THEN note_tags.assigned_by
        ELSE excluded.assigned_by
      END,
      deletable = CASE
        WHEN note_tags.deletable = 0 THEN 0
        ELSE excluded.deletable
      END
    """,
    bindings: [
      .id(noteId),
      .id(storedTag.tagId),
      .text(provenance.rawValue),
      .optionalText(assignedBy),
      .int(deletable ? 1 : 0),
      .text(NoteStoreClock.system.now())
    ]
  )
}

func ensureTag(_ tag: NoteTagInput, in database: SQLiteDatabase) throws {
  if let classId = tag.classId, !classId.isEmpty {
    _ = try requireTagClass(classId: classId, in: database)
  }
  if let existing = try findNonFolderTag(name: tag.name, in: database) {
    if existing.classId == nil, let classId = tag.classId, !classId.isEmpty {
      try database.execute(
        "UPDATE tags SET class_id = ? WHERE tag_id = ?",
        bindings: [.id(classId), .id(existing.tagId)]
      )
    }
    return
  }
  do {
    try database.execute(
      """
      INSERT INTO tags (tag_id, name, class_id, is_system, created_at)
      VALUES (?, ?, ?, 0, ?)
      """,
      bindings: [
        .id(TagID.generate()),
        .text(tag.name),
        .optionalID(tag.classId),
        .text(NoteStoreClock.system.now())
      ]
    )
  } catch let error as SQLiteError where isSQLiteUniqueConstraintViolation(error) {
    guard try findNonFolderTag(name: tag.name, in: database) != nil else {
      throw error
    }
  }
}
