#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public extension NoteService {
  /// Issues a credential for an account. Without an explicit user it belongs to
  /// whichever account this service value acts as, which is the default user on
  /// an unscoped value.
  @discardableResult
  func registerAPIClient(
    displayName: String,
    bearerToken: String,
    userId: UserID? = nil
  ) throws -> NoteAPIClient {
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let clientName = trimmedName.isEmpty ? "Unnamed client" : trimmedName
    let ownerUserId = userId ?? writeOwnerUserId()
    return try driver.withDatabase { database in
      try database.transaction { db in
        let owner = try requireUser(ownerUserId, in: db)
        guard owner.isEnabled else {
          throw NoteServiceError.invalidInput("user is disabled: \(ownerUserId)")
        }
        let now = NoteStoreClock.system.now()
        let clientId = APIClientID.generate()
        try db.execute(
          """
          INSERT INTO api_clients (
            client_id, display_name, token_hash, user_id, created_at, last_seen_at, revoked_at
          ) VALUES (?, ?, ?, ?, ?, NULL, NULL)
          """,
          bindings: [
            .id(clientId),
            .text(clientName),
            .text(Self.apiTokenHash(for: bearerToken)),
            .id(ownerUserId),
            .text(now)
          ]
        )
        return try requireAPIClient(clientId, in: db)
      }
    }
  }

  func listAPIClients(includeRevoked: Bool = false) throws -> [NoteAPIClient] {
    try driver.withDatabase { database in
      let predicate = includeRevoked ? "" : "WHERE revoked_at IS NULL"
      return try database.query(
        """
        SELECT client_id, display_name, token_hash, user_id, created_at, last_seen_at, revoked_at
        FROM api_clients
        \(predicate)
        ORDER BY created_at DESC, client_id
        """
      ).map(apiClient(from:))
    }
  }

  @discardableResult
  func revokeAPIClient(clientId: APIClientID) throws -> NoteAPIClient {
    try driver.withDatabase { database in
      try database.transaction { db in
        _ = try requireAPIClient(clientId, in: db)
        try db.execute(
          "UPDATE api_clients SET revoked_at = coalesce(revoked_at, ?) WHERE client_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .id(clientId)]
        )
        return try requireAPIClient(clientId, in: db)
      }
    }
  }

  func authenticateAPIClient(bearerToken: String) throws -> NoteAPIClient? {
    let tokenHash = Self.apiTokenHash(for: bearerToken)
    return try driver.withDatabase { database in
      try database.transaction { db in
        let rows = try db.query(
          """
          SELECT client_id, display_name, token_hash, user_id, created_at, last_seen_at, revoked_at
          FROM api_clients
          WHERE token_hash = ? AND revoked_at IS NULL
          LIMIT 1
          """,
          bindings: [.text(tokenHash)]
        )
        guard let row = rows.first else {
          return nil
        }
        let client = try apiClient(from: row)
        try db.execute(
          "UPDATE api_clients SET last_seen_at = ? WHERE client_id = ?",
          bindings: [.text(NoteStoreClock.system.now()), .id(client.clientId)]
        )
        return try requireAPIClient(client.clientId, in: db)
      }
    }
  }

  static func apiTokenHash(for token: String) -> String {
    let digest = SHA256.hash(data: Data(token.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

private func requireAPIClient(_ clientId: APIClientID, in database: SQLiteDatabase) throws -> NoteAPIClient {
  let rows = try database.query(
    """
    SELECT client_id, display_name, token_hash, user_id, created_at, last_seen_at, revoked_at
    FROM api_clients
    WHERE client_id = ?
    LIMIT 1
    """,
    bindings: [.id(clientId)]
  )
  guard let row = rows.first else {
    throw NoteServiceError.notFound("api client not found: \(clientId)")
  }
  return try apiClient(from: row)
}

private func apiClient(from row: SQLiteRow) throws -> NoteAPIClient {
  guard let clientId = row.identifier("client_id", as: APIClientID.self),
        let displayName = row["display_name"],
        let tokenHash = row["token_hash"],
        let userId = row.identifier("user_id", as: UserID.self),
        let createdAt = row["created_at"] else {
    throw NoteServiceError.invalidRow("api client row is missing required fields")
  }
  return NoteAPIClient(
    clientId: clientId,
    displayName: displayName,
    tokenHash: tokenHash,
    userId: userId,
    createdAt: createdAt,
    lastSeenAt: row["last_seen_at"] ?? nil,
    revokedAt: row["revoked_at"] ?? nil
  )
}
