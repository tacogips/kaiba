import Foundation

// Which users may reach which libraries (`design-docs/specs/library.md`).
//
// `auth_required` answers whether a caller with no credential gets in at all.
// Membership answers the other half — which authenticated users do. The two
// are separate on purpose: an open library needs no membership rows, because
// "open" already means everyone.

public enum NoteLibraryRole: String, Codable, Equatable, Sendable {
  case owner
  case member
}

public struct NoteLibraryMember: Codable, Equatable, Sendable {
  public var libraryId: LibraryID
  public var userId: UserID
  public var displayName: String?
  public var email: String?
  public var role: NoteLibraryRole
  public var grantedAt: String
  public var grantedBy: UserID?

  public init(
    libraryId: LibraryID,
    userId: UserID,
    displayName: String? = nil,
    email: String? = nil,
    role: NoteLibraryRole,
    grantedAt: String,
    grantedBy: UserID? = nil
  ) {
    self.libraryId = libraryId
    self.userId = userId
    self.displayName = displayName
    self.email = email
    self.role = role
    self.grantedAt = grantedAt
    self.grantedBy = grantedBy
  }
}

public extension NoteService {
  /// Lets one user reach a library. Re-granting updates the role rather than
  /// failing, so an operator can promote a member without revoking first.
  @discardableResult
  func grantLibraryAccess(
    libraryName: String,
    userId: UserID,
    role: NoteLibraryRole = .member
  ) throws -> NoteLibraryMember {
    let normalizedName = try normalizedLibraryName(libraryName)
    return try driver.withDatabase { database in
      try database.transaction { db in
        let library = try requireLibrary(name: normalizedName, in: db)
        let user = try requireUser(userId, in: db)
        try insertLibraryMember(
          libraryId: library.libraryId,
          userId: user.userId,
          role: role,
          in: db
        )
        return try requireLibraryMember(libraryId: library.libraryId, userId: user.userId, in: db)
      }
    }
  }

  /// Takes a user's access away. Their notebooks stay where they are: a
  /// library is a place, not an ownership record, and deleting content on a
  /// revoke would destroy work an operator only meant to hide.
  func revokeLibraryAccess(libraryName: String, userId: UserID) throws {
    let normalizedName = try normalizedLibraryName(libraryName)
    try driver.withDatabase { database in
      try database.transaction { db in
        let library = try requireLibrary(name: normalizedName, in: db)
        guard try libraryMemberRow(libraryId: library.libraryId, userId: userId, in: db) != nil else {
          throw NoteServiceError.notFound("\(userId) is not a member of \(normalizedName)")
        }
        try db.execute(
          "DELETE FROM library_members WHERE library_id = ? AND user_id = ?",
          bindings: [.id(library.libraryId), .id(userId)]
        )
      }
    }
  }

  func listLibraryMembers(libraryName: String) throws -> [NoteLibraryMember] {
    let normalizedName = try normalizedLibraryName(libraryName)
    return try driver.withDatabase { database in
      let library = try requireLibrary(name: normalizedName, in: database)
      // Reading the roster is reading the library: a caller that cannot reach
      // it must not learn who can.
      try requireLibraryReach(
        libraryId: library.libraryId,
        subject: normalizedName,
        kind: .library,
        in: database
      )
      return try database.query(
        """
        SELECT m.library_id, m.user_id, m.role, m.granted_at, m.granted_by,
          u.display_name AS display_name, u.email AS email
        FROM library_members m
        JOIN users u ON u.user_id = m.user_id
        WHERE m.library_id = ?
        ORDER BY m.role, u.display_name, m.user_id
        """,
        bindings: [.id(library.libraryId)]
      ).map(noteLibraryMember(from:))
    }
  }

  /// The libraries one account may reach, whatever this service value is
  /// currently scoped to. Backs `kaiba library list --user`.
  func libraries(forUser userId: UserID) throws -> [NoteLibrary] {
    try driver.withDatabase { database in
      _ = try requireUser(userId, in: database)
      return try database.query(
        """
        SELECT library_id, name, title, auth_required, is_default, created_at, created_by,
          (SELECT COUNT(*) FROM notebooks WHERE notebooks.library_id = libraries.library_id)
            AS notebook_count
        FROM libraries
        WHERE auth_required = 0
          OR library_id IN (SELECT library_id FROM library_members WHERE user_id = ?)
        ORDER BY is_default DESC, name
        """,
        bindings: [.id(userId)]
      ).map(noteLibrary(from:))
    }
  }
}

extension NoteService {
  func insertLibraryMember(
    libraryId: LibraryID,
    userId: UserID,
    role: NoteLibraryRole,
    in db: SQLiteDatabase
  ) throws {
    try db.execute(
      """
      INSERT INTO library_members (library_id, user_id, role, granted_at, granted_by)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(library_id, user_id) DO UPDATE SET role = excluded.role
      """,
      bindings: [
        .id(libraryId),
        .id(userId),
        .text(role.rawValue),
        .text(NoteStoreClock.system.now()),
        .id(writeOwnerUserId())
      ]
    )
  }

  func isLibraryMember(libraryId: LibraryID, userId: UserID, in db: SQLiteDatabase) -> Bool {
    let rows = (try? libraryMemberRow(libraryId: libraryId, userId: userId, in: db)) ?? nil
    return rows != nil
  }
}

func libraryMemberRow(
  libraryId: LibraryID,
  userId: UserID,
  in database: SQLiteDatabase
) throws -> SQLiteRow? {
  try database.query(
    """
    SELECT library_id, user_id, role, granted_at, granted_by
    FROM library_members
    WHERE library_id = ? AND user_id = ?
    LIMIT 1
    """,
    bindings: [.id(libraryId), .id(userId)]
  ).first
}

func requireLibraryMember(
  libraryId: LibraryID,
  userId: UserID,
  in database: SQLiteDatabase
) throws -> NoteLibraryMember {
  guard let row = try libraryMemberRow(libraryId: libraryId, userId: userId, in: database) else {
    throw NoteServiceError.notFound("library member not found: \(userId)")
  }
  return try noteLibraryMember(from: row)
}

func noteLibraryMember(from row: SQLiteRow) throws -> NoteLibraryMember {
  guard let libraryId = row.identifier("library_id", as: LibraryID.self),
        let userId = row.identifier("user_id", as: UserID.self),
        let rawRole = row["role"],
        let role = NoteLibraryRole(rawValue: rawRole),
        let grantedAt = row["granted_at"] else {
    throw NoteServiceError.invalidRow("library member row is missing required fields")
  }
  return NoteLibraryMember(
    libraryId: libraryId,
    userId: userId,
    displayName: row["display_name"] ?? nil,
    email: row["email"] ?? nil,
    role: role,
    grantedAt: grantedAt,
    grantedBy: row.identifier("granted_by", as: UserID.self)
  )
}
