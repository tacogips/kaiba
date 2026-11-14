import Foundation

/// Per-user personal-agent credentials (`design-docs/specs/user-agent-tools.md`,
/// UA1). The secret is written and cleared through these methods and read
/// only by `storedUserAgentCredential`, which the dispatcher uses to build a
/// runtime for one turn. Everything a caller can observe is the summary.
public extension NoteService {
  /// Stores (or replaces) the credential for the acting user, or for
  /// `targetUserId` when the caller is the unscoped operator or an enabled
  /// administrator. Returns the observable summary.
  @discardableResult
  func setUserAgentCredential(
    _ input: UserAgentCredentialInput,
    targetUserId: UserID? = nil,
    customBaseURLAllowed: Bool = false
  ) throws -> UserAgentCredentialSummary {
    let apiKey = try UserAgentCredentialValidation.validatedKey(input.apiKey)
    let model = try UserAgentCredentialValidation.validatedModel(input.defaultModel)
    let baseURL = try UserAgentCredentialValidation.validatedBaseURL(
      input.baseURL,
      provider: input.provider,
      customBaseURLAllowed: customBaseURLAllowed
    )
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        let owner = try resolveUserAgentCredentialOwner(targetUserId, in: db)
        let now = NoteStoreClock.system.now()
        try db.execute(
          """
          INSERT INTO user_agent_credentials (
            user_id, provider, api_key, base_url, default_model, enabled, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(user_id) DO UPDATE SET
            provider = excluded.provider,
            api_key = excluded.api_key,
            base_url = excluded.base_url,
            default_model = excluded.default_model,
            enabled = excluded.enabled,
            updated_at = excluded.updated_at
          """,
          bindings: [
            .id(owner),
            .text(input.provider.rawValue),
            .text(apiKey),
            .optionalText(baseURL?.absoluteString),
            .text(model),
            .int(input.enabled ? 1 : 0),
            .text(now),
            .text(now)
          ]
        )
        guard let stored = try userAgentCredentialRow(userId: owner, in: db) else {
          throw NoteServiceError.invalidRow("user agent credential was not stored")
        }
        return stored.summary
      }
    }
  }

  /// The observable summary for the acting user (or `targetUserId` under the
  /// same rules as `setUserAgentCredential`); nil when none is stored.
  func userAgentCredentialSummary(targetUserId: UserID? = nil) throws -> UserAgentCredentialSummary? {
    try driver.withDatabase { database in
      try database.transaction { db in
        let owner = try resolveUserAgentCredentialOwner(targetUserId, in: db)
        return try userAgentCredentialRow(userId: owner, in: db)?.summary
      }
    }
  }

  /// Flips `enabled` without re-entering the key. Returns nil when no
  /// credential is stored.
  @discardableResult
  func setUserAgentCredentialEnabled(
    _ enabled: Bool,
    targetUserId: UserID? = nil
  ) throws -> UserAgentCredentialSummary? {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        let owner = try resolveUserAgentCredentialOwner(targetUserId, in: db)
        try db.execute(
          "UPDATE user_agent_credentials SET enabled = ?, updated_at = ? WHERE user_id = ?",
          bindings: [.int(enabled ? 1 : 0), .text(NoteStoreClock.system.now()), .id(owner)]
        )
        return try userAgentCredentialRow(userId: owner, in: db)?.summary
      }
    }
  }

  /// Deletes the credential. Returns whether a row existed.
  @discardableResult
  func clearUserAgentCredential(targetUserId: UserID? = nil) throws -> Bool {
    try driver.withDatabase { database in
      try database.transaction { db in
        try requireEnabledActingUser(in: db)
        let owner = try resolveUserAgentCredentialOwner(targetUserId, in: db)
        let removed = try db.executeAndReturnChangedRowCount(
          "DELETE FROM user_agent_credentials WHERE user_id = ?",
          bindings: [.id(owner)]
        )
        return removed > 0
      }
    }
  }
}

extension NoteService {
  /// The full credential for `userId`, including the secret. Not gated by the
  /// principal: the dispatcher calls it with the originating user id it has
  /// already verified, and nothing else may call it.
  func storedUserAgentCredential(userId: UserID) throws -> UserAgentCredential? {
    try driver.withDatabase { database in
      try userAgentCredentialRow(userId: userId, in: database)
    }
  }

  /// UA1 access rules. Unauthenticated principals see nothing; a scoped user
  /// reaches only itself unless it is an enabled administrator; the unscoped
  /// operator must name the target explicitly.
  func resolveUserAgentCredentialOwner(
    _ targetUserId: UserID?,
    in database: SQLiteDatabase
  ) throws -> UserID {
    guard !isUnauthenticatedPrincipal else {
      throw NoteServiceError.notFound("user agent credential not found")
    }
    if let actingUserId {
      guard let targetUserId, targetUserId != actingUserId else {
        return actingUserId
      }
      let acting = try requireUser(actingUserId, in: database)
      guard acting.disabledAt == nil, acting.isAdmin else {
        throw NoteServiceError.notFound("user agent credential not found")
      }
      _ = try requireUser(targetUserId, in: database)
      return targetUserId
    }
    guard let targetUserId else {
      throw NoteServiceError.invalidInput(
        "the unscoped operator must name the credential owner (--user <id>)"
      )
    }
    _ = try requireUser(targetUserId, in: database)
    return targetUserId
  }

  private func userAgentCredentialRow(
    userId: UserID,
    in database: SQLiteDatabase
  ) throws -> UserAgentCredential? {
    guard let row = try database.query(
      """
      SELECT user_id, provider, api_key, base_url, default_model, enabled, created_at, updated_at
      FROM user_agent_credentials
      WHERE user_id = ?
      LIMIT 1
      """,
      bindings: [.id(userId)]
    ).first else {
      return nil
    }
    guard let provider = UserAgentProvider(rawValue: row.string("provider")) else {
      throw NoteServiceError.invalidRow("unknown user agent provider: \(row.string("provider"))")
    }
    return UserAgentCredential(
      userId: userId,
      provider: provider,
      apiKey: row.string("api_key"),
      baseURL: row["base_url"].flatMap(URL.init(string:)),
      defaultModel: row.string("default_model"),
      enabled: row.string("enabled") == "1",
      createdAt: row.string("created_at"),
      updatedAt: row.string("updated_at")
    )
  }
}
