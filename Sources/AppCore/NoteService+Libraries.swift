import Foundation

// Libraries. A library is a named set of notebooks, and `auth_required`
// decides whether an unauthenticated caller may see it at all. The default
// library is seeded when the store is first prepared
// (`NoteStoreSchema.seedDefaultLibrary`), so these entry points never have to
// invent one (`design-docs/specs/library.md`).

public extension NoteService {
  /// The library notebooks land in when none is selected. Present in every
  /// prepared store; a store missing it is corrupt, not empty.
  func defaultLibrary() throws -> NoteLibrary {
    guard let library = try library(id: NoteStoreSchema.defaultLibraryId) else {
      throw NoteServiceError.notFound("default library is missing from the store")
    }
    return library
  }

  @discardableResult
  func createLibrary(
    name: String,
    title: String? = nil,
    authRequired: Bool = true
  ) throws -> NoteLibrary {
    let normalizedName = try normalizedLibraryName(name)
    let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : normalizedName
    return try driver.withDatabase { database in
      try database.transaction { db in
        if try libraryRow(name: normalizedName, in: db) != nil {
          throw NoteServiceError.invalidInput("a library already exists named \(normalizedName)")
        }
        let libraryId = LibraryID.generate()
        try db.execute(
          """
          INSERT INTO libraries (
            library_id, name, title, auth_required, is_default, created_at, created_by
          ) VALUES (?, ?, ?, ?, 0, ?, ?)
          """,
          bindings: [
            .id(libraryId),
            .text(normalizedName),
            .text(resolvedTitle),
            .int(authRequired ? 1 : 0),
            .text(NoteStoreClock.system.now()),
            .id(writeOwnerUserId())
          ]
        )
        // The creator is a member, or an authenticated caller would lock
        // itself out of the library it just made.
        try insertLibraryMember(
          libraryId: libraryId,
          userId: writeOwnerUserId(),
          role: .owner,
          in: db
        )
        return try requireLibrary(libraryId, in: db)
      }
    }
  }

  /// The libraries this caller may see: the open ones, plus the ones an
  /// authenticated account is a member of, and every one for an admin. A
  /// caller must not even learn that the others exist
  /// (`design-docs/specs/library.md`).
  func listLibraries() throws -> [NoteLibrary] {
    try driver.withDatabase { database in
      var predicate = ""
      var predicateBindings: [SQLiteValue] = []
      if isUnauthenticatedPrincipal {
        // Checked before membership: the note API resolves a credential-less
        // request to the default user, and a grant that account holds must not
        // become a way in.
        predicate = "WHERE auth_required = 0"
      } else if isActingAdmin(in: database) {
        predicate = ""
      } else if let actingUserId {
        predicate = """
          WHERE auth_required = 0
            OR library_id IN (SELECT library_id FROM library_members WHERE user_id = ?)
          """
        predicateBindings.append(.id(actingUserId))
      }
      return try database.query(
        """
        SELECT library_id, name, title, auth_required, is_default, created_at, created_by,
          (SELECT COUNT(*) FROM notebooks WHERE notebooks.library_id = libraries.library_id)
            AS notebook_count
        FROM libraries
        \(predicate)
        ORDER BY is_default DESC, name
        """,
        bindings: predicateBindings
      ).map(noteLibrary(from:))
    }
  }

  func library(id libraryId: LibraryID) throws -> NoteLibrary? {
    try driver.withDatabase { database in
      try libraryRow(id: libraryId, in: database).map(noteLibrary(from:))
    }
  }

  /// Looks a library up by the handle a command types, normalized the same way
  /// `createLibrary` stores it, so selection cannot miss one over letter case.
  func library(name: String) throws -> NoteLibrary? {
    let normalizedName = try normalizedLibraryName(name)
    return try driver.withDatabase { database in
      try libraryRow(name: normalizedName, in: database).map(noteLibrary(from:))
    }
  }

  @discardableResult
  func updateLibrary(
    name: String,
    title: String? = nil,
    authRequired: Bool? = nil
  ) throws -> NoteLibrary {
    let normalizedName = try normalizedLibraryName(name)
    return try driver.withDatabase { database in
      try database.transaction { db in
        let library = try requireLibrary(name: normalizedName, in: db)
        if let title {
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else {
            throw NoteServiceError.invalidInput("--title cannot be empty")
          }
          try db.execute(
            "UPDATE libraries SET title = ? WHERE library_id = ?",
            bindings: [.text(trimmed), .id(library.libraryId)]
          )
        }
        if let authRequired {
          try db.execute(
            "UPDATE libraries SET auth_required = ? WHERE library_id = ?",
            bindings: [.int(authRequired ? 1 : 0), .id(library.libraryId)]
          )
        }
        return try requireLibrary(library.libraryId, in: db)
      }
    }
  }

  /// Removes an empty library. Deletion never cascades into notebooks: moving
  /// them out first is the operator's explicit act, and a cascade here would
  /// destroy notes that nothing else in the product can destroy by accident.
  func deleteLibrary(name: String) throws {
    let normalizedName = try normalizedLibraryName(name)
    try driver.withDatabase { database in
      try database.transaction { db in
        let library = try requireLibrary(name: normalizedName, in: db)
        if library.isDefault {
          throw NoteServiceError.invalidInput("the default library cannot be deleted")
        }
        let count = try notebookCount(libraryId: library.libraryId, in: db)
        guard count == 0 else {
          throw NoteServiceError.invalidInput(
            "library \(normalizedName) still holds \(count) notebooks; move them out first"
          )
        }
        // Grants are metadata about the library, not content in it, so they go
        // with it. Notebooks never do — that is the guard above.
        try db.execute(
          "DELETE FROM library_members WHERE library_id = ?",
          bindings: [.id(library.libraryId)]
        )
        try db.execute(
          "DELETE FROM libraries WHERE library_id = ?",
          bindings: [.id(library.libraryId)]
        )
      }
    }
  }

  /// Re-parents one notebook. Notes, tags, files, and comments reach their
  /// library through the notebook, so they move with it and cannot drift out
  /// of agreement with it.
  @discardableResult
  func moveNotebook(_ notebookId: NotebookID, toLibrary name: String) throws -> NoteLibrary {
    let normalizedName = try normalizedLibraryName(name)
    return try driver.withDatabase { database in
      try database.transaction { db in
        let library = try requireLibrary(name: normalizedName, in: db)
        _ = try requireNotebook(notebookId, in: db)
        try db.execute(
          "UPDATE notebooks SET library_id = ?, updated_at = ? WHERE notebook_id = ?",
          bindings: [
            .id(library.libraryId),
            .text(NoteStoreClock.system.now()),
            .id(notebookId)
          ]
        )
        try stampNotebookUpdated(notebookId, in: db)
        return try requireLibrary(library.libraryId, in: db)
      }
    }
  }

  /// A copy of this service that acts in one library: new notebooks land in it
  /// and notebook reads are filtered to it. `nil` restores the view spanning
  /// every library the caller may see.
  func scoped(toLibrary libraryId: LibraryID?) -> NoteService {
    var copy = self
    copy.actingLibraryId = libraryId
    return copy
  }

  /// A copy of this service for a caller that presented no credential. The
  /// note API still resolves such a request to the default user, so the
  /// account alone cannot tell the two apart and the marker has to be
  /// explicit.
  func unauthenticated(_ isUnauthenticated: Bool = true) -> NoteService {
    var copy = self
    copy.isUnauthenticatedPrincipal = isUnauthenticated
    return copy
  }

  /// The library recorded for writes made through this service value.
  func writeLibraryId() -> LibraryID {
    actingLibraryId ?? NoteStoreSchema.defaultLibraryId
  }
}

extension NoteService {
  /// The library a derived notebook belongs in. An agent conversation or a
  /// consolidated memory built from a source note stays in that note's
  /// library: landing it in the default library would move content out of an
  /// authenticated library into an unauthenticated one.
  func inheritedLibraryId(fromSourceNoteIds noteIds: [NoteID], in db: SQLiteDatabase) throws -> LibraryID {
    for noteId in noteIds {
      let rows = try db.query(
        """
        SELECT notebooks.library_id AS library_id
        FROM notes
        JOIN notebooks ON notebooks.notebook_id = notes.notebook_id
        WHERE notes.note_id = ?
        LIMIT 1
        """,
        bindings: [.id(noteId)]
      )
      if let libraryId = rows.first?.identifier("library_id", as: LibraryID.self) {
        return libraryId
      }
    }
    return writeLibraryId()
  }

  /// Restricts a notebook query to what this caller may see. An explicit
  /// selection wins; otherwise an unscoped caller is held to the libraries
  /// that do not require authentication.
  func appendLibraryPredicates(
    alias: String,
    predicates: inout [String],
    bindings: inout [SQLiteValue]
  ) {
    if let actingLibraryId {
      predicates.append("\(alias).library_id = ?")
      bindings.append(.id(actingLibraryId))
      return
    }
    if isUnauthenticatedPrincipal {
      predicates.append(
        "\(alias).library_id IN (SELECT library_id FROM libraries WHERE auth_required = 0)"
      )
    }
  }

  func notebookCount(libraryId: LibraryID, in database: SQLiteDatabase) throws -> Int {
    let rows = try database.query(
      "SELECT COUNT(*) AS notebook_count FROM notebooks WHERE library_id = ?",
      bindings: [.id(libraryId)]
    )
    return rows.first?["notebook_count"].flatMap(Int.init) ?? 0
  }
}

/// Library handles are lowercased and trimmed, and are deliberately narrow:
/// they appear in `--library`, in a kinko scope, and in a config binding, so a
/// name with a space or a slash in it would be ambiguous in all three.
func normalizedLibraryName(_ name: String) throws -> String {
  let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  guard !trimmed.isEmpty else {
    throw NoteServiceError.invalidInput("a library name is required")
  }
  let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
  guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
    throw NoteServiceError.invalidInput(
      "library names may use letters, digits, '-', '_', and '.': \(name)"
    )
  }
  return trimmed
}

func requireLibrary(_ libraryId: LibraryID, in database: SQLiteDatabase) throws -> NoteLibrary {
  guard let row = try libraryRow(id: libraryId, in: database) else {
    throw NoteServiceError.notFound("library not found: \(libraryId)")
  }
  return try noteLibrary(from: row)
}

func requireLibrary(name: String, in database: SQLiteDatabase) throws -> NoteLibrary {
  guard let row = try libraryRow(name: name, in: database) else {
    throw NoteServiceError.notFound("library not found: \(name)")
  }
  return try noteLibrary(from: row)
}

func libraryRow(id libraryId: LibraryID, in database: SQLiteDatabase) throws -> SQLiteRow? {
  try database.query(
    """
    SELECT library_id, name, title, auth_required, is_default, created_at, created_by
    FROM libraries
    WHERE library_id = ?
    LIMIT 1
    """,
    bindings: [.id(libraryId)]
  ).first
}

func libraryRow(name: String, in database: SQLiteDatabase) throws -> SQLiteRow? {
  try database.query(
    """
    SELECT library_id, name, title, auth_required, is_default, created_at, created_by
    FROM libraries
    WHERE name = ?
    LIMIT 1
    """,
    bindings: [.text(name)]
  ).first
}

func noteLibrary(from row: SQLiteRow) throws -> NoteLibrary {
  guard let libraryId = row.identifier("library_id", as: LibraryID.self),
        let name = row["name"],
        let title = row["title"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("library row is missing required fields")
  }
  return NoteLibrary(
    libraryId: libraryId,
    name: name,
    title: title,
    authRequired: row["auth_required"] == "1",
    isDefault: row["is_default"] == "1",
    createdAt: createdAt,
    createdBy: row.identifier("created_by", as: UserID.self),
    notebookCount: row["notebook_count"].flatMap(Int.init)
  )
}
