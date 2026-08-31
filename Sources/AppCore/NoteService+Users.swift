import Foundation

// Accounts. The default user is seeded when the store is first prepared
// (`NoteStoreSchema.seedDefaultUser`), so these entry points never have to
// invent one: every store has a principal to attribute writes to, and an
// unauthenticated host simply acts as it (`design-docs/specs/multi-user.md`).

public extension NoteService {
  /// The account unauthenticated requests act as. Present in every prepared
  /// store; a store missing it is corrupt, not empty.
  func defaultUser() throws -> NoteUser {
    guard let user = try user(id: NoteStoreSchema.defaultUserId) else {
      throw NoteServiceError.notFound("default user is missing from the store")
    }
    return user
  }

  @discardableResult
  func createUser(email: String?, displayName: String, isAdmin: Bool = false) throws -> NoteUser {
    let normalizedEmail = try normalizedUserEmail(email)
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = trimmedName.isEmpty ? (normalizedEmail ?? "Unnamed user") : trimmedName
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        if let normalizedEmail, try userRow(email: normalizedEmail, in: db) != nil {
          throw NoteServiceError.invalidInput("a user already exists for \(normalizedEmail)")
        }
        let userId = UserID.generate()
        try db.execute(
          """
          INSERT INTO users (
            user_id, email, display_name, is_default, is_admin, created_at, disabled_at
          ) VALUES (?, ?, ?, 0, ?, ?, NULL)
          """,
          bindings: [
            .id(userId),
            .optionalText(normalizedEmail),
            .text(name),
            .int(isAdmin ? 1 : 0),
            .text(NoteStoreClock.system.now())
          ]
        )
        return try requireUser(userId, in: db)
      }
    }
  }

  func listUsers(includeDisabled: Bool = false) throws -> [NoteUser] {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try userListAfterAuthorizationHook?(db)
        let predicate = includeDisabled ? "" : "WHERE disabled_at IS NULL"
        return try db.query(
          """
          SELECT user_id, email, display_name, is_default, is_admin, created_at, disabled_at
          FROM users
          \(predicate)
          ORDER BY is_default DESC, created_at, user_id
          """
        ).map(noteUser(from:))
      }
    }
  }

  func user(id userId: UserID) throws -> NoteUser? {
    try driver.withDatabase { database in
      guard try canReadUser(userId, in: database) else {
        return nil
      }
      return try userRow(id: userId, in: database).map(noteUser(from:))
    }
  }

  /// Looks a user up by address, normalized the same way `createUser` stores
  /// it, so a login flow cannot miss an account over letter case.
  func user(email: String) throws -> NoteUser? {
    guard let normalizedEmail = try normalizedUserEmail(email) else {
      return nil
    }
    return try driver.withDatabase { database in
      guard let user = try userRow(email: normalizedEmail, in: database).map(noteUser(from:)),
            try canReadUser(user.userId, in: database) else {
        return nil
      }
      return user
    }
  }

  @discardableResult
  func setUserDisabled(userId: UserID, disabled: Bool) throws -> NoteUser {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        let user = try requireUser(userId, in: db)
        if disabled && user.isDefault {
          throw NoteServiceError.invalidInput("the default user cannot be disabled")
        }
        if disabled && user.isAdmin {
          try requireAnotherEnabledAdmin(besides: userId, action: "disabled", in: db)
        }
        try db.execute(
          "UPDATE users SET disabled_at = ? WHERE user_id = ?",
          bindings: [
            disabled ? .text(NoteStoreClock.system.now()) : .null,
            .id(userId)
          ]
        )
        return try requireUser(userId, in: db)
      }
    }
  }

  /// Promotes or demotes an account. A store always keeps at least one
  /// enabled admin: an unauthenticated host acts as one, and a library that
  /// requires authentication would otherwise be reachable by nobody
  /// (`design-docs/specs/multi-user.md`).
  @discardableResult
  func setUserAdmin(userId: UserID, isAdmin: Bool) throws -> NoteUser {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        let user = try requireUser(userId, in: db)
        if !isAdmin && user.isAdmin {
          try requireAnotherEnabledAdmin(besides: userId, action: "demoted", in: db)
        }
        if isAdmin && user.disabledAt != nil {
          throw NoteServiceError.invalidInput("a disabled user cannot be made an admin: \(userId)")
        }
        try db.execute(
          "UPDATE users SET is_admin = ? WHERE user_id = ?",
          bindings: [.int(isAdmin ? 1 : 0), .id(userId)]
        )
        return try requireUser(userId, in: db)
      }
    }
  }

  /// The enabled admins, default user first.
  func listAdminUsers() throws -> [NoteUser] {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        try userListAfterAuthorizationHook?(db)
        return try db.query(
          """
          SELECT user_id, email, display_name, is_default, is_admin, created_at, disabled_at
          FROM users
          WHERE is_admin = 1 AND disabled_at IS NULL
          ORDER BY is_default DESC, created_at, user_id
          """
        ).map(noteUser(from:))
      }
    }
  }

  /// A copy of this service that acts as one user: new notebooks take that
  /// owner, and notebook reads are filtered to it. `nil` restores the unscoped
  /// view used by the CLI and by internal bootstrap paths.
  func scoped(to userId: UserID?) -> NoteService {
    var copy = self
    copy.actingUserId = userId
    return copy
  }

  /// The owner recorded for writes made through this service value.
  func writeOwnerUserId() -> UserID {
    actingUserId ?? NoteStoreSchema.defaultUserId
  }
}

// Attribution. Every write records who made it, so a shared store can answer
// "who wrote this" without reading the change feed. Stamping runs inside the
// caller's transaction, immediately after the row is written, which keeps the
// column lists of the existing statements untouched.
extension NoteService {
  /// Looks up a user without applying the request principal. Authentication and
  /// login workflows need this after proving a credential or login code; the
  /// public lookup methods intentionally do not expose foreign accounts.
  func storedUser(id userId: UserID) throws -> NoteUser? {
    try driver.withDatabase { database in
      try userRow(id: userId, in: database).map(noteUser(from:))
    }
  }

  func storedUser(email: String) throws -> NoteUser? {
    guard let normalizedEmail = try normalizedUserEmail(email) else {
      return nil
    }
    return try driver.withDatabase { database in
      try userRow(email: normalizedEmail, in: database).map(noteUser(from:))
    }
  }

  /// User records are account metadata, not catalog data. A scoped caller can
  /// read only itself unless it is an enabled administrator; foreign and
  /// missing records therefore remain indistinguishable.
  func canReadUser(_ userId: UserID, in database: SQLiteDatabase) throws -> Bool {
    guard let actingUserId else {
      return !isUnauthenticatedPrincipal
    }
    guard actingUserId != userId else {
      return true
    }
    guard !isUnauthenticatedPrincipal else {
      return false
    }
    let actingUser = try requireUser(actingUserId, in: database)
    return actingUser.disabledAt == nil && actingUser.isAdmin
  }

  /// Checks the scoped writer at a workflow boundary. Mutating operations must
  /// still call the database variant below so the check and write share one
  /// transaction.
  func requireEnabledActingUser() throws {
    try driver.withDatabase { database in
      try requireEnabledActingUser(in: database)
    }
  }

  /// Revalidates the scoped writer inside the transaction that will mutate
  /// data. Queued AI work can outlive account disablement, so checking only
  /// when the dispatcher starts is insufficient.
  func requireEnabledActingUser(in database: SQLiteDatabase) throws {
    try requireActiveAutoActionDispatchLease(in: database)
    guard let actingUserId else { return }
    guard try requireUser(actingUserId, in: database).disabledAt == nil else {
      throw NoteServiceError.accountUnavailable(
        "account is disabled: \(actingUserId)"
      )
    }
  }

  /// Account and store-control operations are available to the local operator
  /// and to enabled administrators, never to an ordinary JWT-scoped caller.
  /// Keeping this check in the caller's transaction prevents a principal from
  /// being demoted or disabled between authorization and the protected write.
  func requireStoreAdministrator(in database: SQLiteDatabase) throws {
    guard !isUnauthenticatedPrincipal else {
      throw NoteServiceError.notFound("control-plane resource not found")
    }
    guard let actingUserId else { return }
    let user = try requireUser(actingUserId, in: database)
    guard user.disabledAt == nil else {
      throw NoteServiceError.accountUnavailable("account is disabled: \(actingUserId)")
    }
    guard user.isAdmin else {
      throw NoteServiceError.notFound("control-plane resource not found")
    }
  }

  func stampNoteCreated(_ noteId: NoteID, in db: SQLiteDatabase) throws {
    try db.execute(
      "UPDATE notes SET created_by = ?, updated_by = ? WHERE note_id = ?",
      bindings: [.id(writeOwnerUserId()), .id(writeOwnerUserId()), .id(noteId)]
    )
  }

  func stampNoteUpdated(_ noteId: NoteID, in db: SQLiteDatabase) throws {
    try db.execute(
      "UPDATE notes SET updated_by = ? WHERE note_id = ?",
      bindings: [.id(writeOwnerUserId()), .id(noteId)]
    )
  }

  func stampNotebookUpdated(_ notebookId: NotebookID, in db: SQLiteDatabase) throws {
    try db.execute(
      "UPDATE notebooks SET updated_by = ? WHERE notebook_id = ?",
      bindings: [.id(writeOwnerUserId()), .id(notebookId)]
    )
  }
}

func normalizedUserEmail(_ email: String?) throws -> String? {
  guard let email else {
    return nil
  }
  let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if trimmed.isEmpty {
    return nil
  }
  // Deliberately shallow: the store only needs a stable key, and address
  // validation belongs to whatever delivers mail to it.
  guard trimmed.contains("@"), !trimmed.hasPrefix("@"), !trimmed.hasSuffix("@") else {
    throw NoteServiceError.invalidInput("not an email address: \(email)")
  }
  return trimmed
}

/// Fails unless some *other* enabled admin remains, so the last one can be
/// neither demoted nor disabled.
func requireAnotherEnabledAdmin(
  besides userId: UserID,
  action: String,
  in database: SQLiteDatabase
) throws {
  let remaining = try database.query(
    """
    SELECT user_id FROM users
    WHERE is_admin = 1 AND disabled_at IS NULL AND user_id <> ?
    LIMIT 1
    """,
    bindings: [.id(userId)]
  )
  guard !remaining.isEmpty else {
    throw NoteServiceError.invalidInput(
      "the last admin cannot be \(action); promote another user first"
    )
  }
}

func requireUser(_ userId: UserID, in database: SQLiteDatabase) throws -> NoteUser {
  guard let row = try userRow(id: userId, in: database) else {
    throw NoteServiceError.notFound("user not found: \(userId)")
  }
  return try noteUser(from: row)
}

func userRow(id userId: UserID, in database: SQLiteDatabase) throws -> SQLiteRow? {
      return try database.query(
    """
    SELECT user_id, email, display_name, is_default, is_admin, created_at, disabled_at
    FROM users
    WHERE user_id = ?
    LIMIT 1
    """,
    bindings: [.id(userId)]
  ).first
}

func userRow(email: String, in database: SQLiteDatabase) throws -> SQLiteRow? {
  try database.query(
    """
    SELECT user_id, email, display_name, is_default, is_admin, created_at, disabled_at
    FROM users
    WHERE email = ?
    LIMIT 1
    """,
    bindings: [.text(email)]
  ).first
}

func noteUser(from row: SQLiteRow) throws -> NoteUser {
  guard let userId = row.identifier("user_id", as: UserID.self),
        let displayName = row["display_name"],
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("user row is missing required fields")
  }
  return NoteUser(
    userId: userId,
    email: row["email"] ?? nil,
    displayName: displayName,
    isDefault: row["is_default"] == "1",
    isAdmin: row["is_admin"] == "1",
    createdAt: createdAt,
    disabledAt: row["disabled_at"] ?? nil
  )
}
