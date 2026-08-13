public extension NoteService {
  @discardableResult
  func defineTagClass(
    classId rawClassId: String,
    label rawLabel: String,
    description rawDescription: String? = nil
  ) throws -> TagClass {
    let classId = rawClassId.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !classId.isEmpty else {
      throw NoteServiceError.invalidInput("tag class id is required")
    }
    guard !label.isEmpty else {
      throw NoteServiceError.invalidInput("tag class label is required")
    }
    return try driver.withDatabase { database in
      try database.transaction { db in
        if let existing = try findTagClass(classId: classId, in: db), existing.isSystem {
          guard existing.label == label && existing.description == description else {
            throw NoteServiceError.protectedTag("system tag class is protected: \(classId)")
          }
          return existing
        }
        try db.execute(
          """
          INSERT INTO tag_classes (class_id, label, description, is_system, created_at)
          VALUES (?, ?, ?, 0, ?)
          ON CONFLICT(class_id) DO UPDATE SET
            label = excluded.label,
            description = excluded.description
          """,
          bindings: [
            .text(classId),
            .text(label),
            .optionalText(description?.isEmpty == true ? nil : description),
            .text(NoteStoreClock.system.now())
          ]
        )
        return try requireTagClass(classId: classId, in: db)
      }
    }
  }

  @discardableResult
  func defineTag(
    name rawName: String,
    classId rawClassId: String? = nil,
    parentTagId rawParentTagId: String? = nil,
    createOnly: Bool = false
  ) throws -> Tag {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let classId = rawClassId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let parentTagId = rawParentTagId?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw NoteServiceError.invalidInput("tag name is required")
    }
    return try driver.withDatabase { database in
      try database.transaction { db in
        if let classId, !classId.isEmpty {
          _ = try requireTagClass(classId: classId, in: db)
        }
        let isFolder = classId == "folder"
        let normalizedParentTagId = parentTagId?.isEmpty == true ? nil : parentTagId
        let existing = isFolder
          ? try findFolderTag(name: name, parentTagId: normalizedParentTagId, in: db)
          : try findNonFolderTag(name: name, in: db)
        if createOnly, existing != nil {
          throw NoteServiceError.invalidInput("tag already exists: \(name)")
        }
        if let existing, existing.isSystem {
          guard existing.classId == classId || classId?.isEmpty != false else {
            throw NoteServiceError.protectedTag("system tag is protected: \(name)")
          }
          guard parentTagId?.isEmpty != false || existing.parentTagId == parentTagId else {
            throw NoteServiceError.protectedTag("system tag is protected: \(name)")
          }
          return existing
        }
        let tagId = existing?.tagId ?? makeNoteId(prefix: "tag")
        if let parentTagId, !parentTagId.isEmpty {
          try validateTagParent(childTagId: tagId, parentTagId: parentTagId, in: db)
        }
        if let existing {
          try db.execute(
            """
            UPDATE tags
            SET class_id = coalesce(?, class_id),
                parent_tag_id = coalesce(?, parent_tag_id)
            WHERE tag_id = ?
            """,
            bindings: [
              .optionalText(classId?.isEmpty == true ? nil : classId),
              .optionalText(normalizedParentTagId),
              .text(existing.tagId)
            ]
          )
          return try requireTag(id: existing.tagId, in: db)
        }
        do {
          try db.execute(
            """
            INSERT INTO tags (tag_id, name, class_id, parent_tag_id, is_system, created_at)
            VALUES (?, ?, ?, ?, 0, ?)
            """,
            bindings: [
              .text(tagId),
              .text(name),
              .optionalText(classId?.isEmpty == true ? nil : classId),
              .optionalText(normalizedParentTagId),
              .text(NoteStoreClock.system.now())
            ]
          )
        } catch let error as SQLiteError where isSQLiteUniqueConstraintViolation(error) {
          let raced = isFolder
            ? try findFolderTag(name: name, parentTagId: normalizedParentTagId, in: db)
            : try findNonFolderTag(name: name, in: db)
          guard let raced else { throw error }
          guard !createOnly else {
            throw NoteServiceError.invalidInput("tag already exists in this identity scope: \(name)")
          }
          return raced
        }
        return try requireTag(id: tagId, in: db)
      }
    }
  }

  func listTags() throws -> [Tag] {
    try driver.withDatabase { database in
      try database.query(
        """
        SELECT tag_id, name, class_id, parent_tag_id, is_system, created_at
        FROM tags
        ORDER BY name, ifnull(parent_tag_id, ''), tag_id
        """
      ).map(noteCatalogTag(from:))
    }
  }

  func listTagClasses() throws -> [TagClass] {
    try driver.withDatabase { database in
      try database.query(
        """
        SELECT class_id, label, description, is_system, created_at
        FROM tag_classes
        ORDER BY class_id
        """
      ).map(noteCatalogTagClass(from:))
    }
  }
}

private func findTagClass(classId: String, in database: SQLiteDatabase) throws -> TagClass? {
  try database.query(
    """
    SELECT class_id, label, description, is_system, created_at
    FROM tag_classes
    WHERE class_id = ?
    LIMIT 1
    """,
    bindings: [.text(classId)]
  ).first.map(noteCatalogTagClass(from:))
}

func requireTagClass(classId: String, in database: SQLiteDatabase) throws -> TagClass {
  guard let tagClass = try findTagClass(classId: classId, in: database) else {
    throw NoteServiceError.notFound("tag class not found: \(classId)")
  }
  return tagClass
}

func requireCatalogTag(name: String, in database: SQLiteDatabase) throws -> Tag {
  guard let tag = try findTag(name: name, in: database) else {
    throw NoteServiceError.notFound("tag not found: \(name)")
  }
  return tag
}

private func noteCatalogTag(from row: SQLiteRow) throws -> Tag {
  guard let tagId = row["tag_id"],
        let name = row["name"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("tag row is missing required fields")
  }
  return Tag(
    tagId: tagId,
    name: name,
    classId: row["class_id"] ?? nil,
    parentTagId: row["parent_tag_id"] ?? nil,
    isSystem: row["is_system"] == "1",
    createdAt: createdAt
  )
}

private func noteCatalogTagClass(from row: SQLiteRow) throws -> TagClass {
  guard let classId = row["class_id"],
        let label = row["label"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("tag class row is missing required fields")
  }
  return TagClass(
    classId: classId,
    label: label,
    description: row["description"] ?? nil,
    isSystem: row["is_system"] == "1",
    createdAt: createdAt
  )
}
