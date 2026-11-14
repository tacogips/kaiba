import Foundation
#if canImport(Security)
import Security
#endif

/// The non-secret result used by the HTTP agent-token route. The route returns
/// the caller's account and expiry, never the store signing key.
public struct KaibaAgentTokenIssue: Equatable, Sendable {
  public var token: String
  public var expiresAt: Int

  public init(token: String, expiresAt: Int) {
    self.token = token
    self.expiresAt = expiresAt
  }
}

public protocol KaibaAgentTokenIssuing: Sendable {
  func issueAgentToken(userId: UserID, ttlSeconds: Int) throws -> KaibaAgentTokenIssue
}

/// The HTTP layer only maps an account-standing refusal to 401.  Store,
/// signing, and other operational failures are deliberately distinct so they
/// are not misreported as bad credentials.
public enum KaibaAgentTokenIssuingError: Error, Equatable, Sendable {
  case accountUnavailable
  case operationFailed
}

// The signing key for kaiba-issued JWTs, and the entry points that mint and
// resolve them. The key lives in the store rather than in a config file: the
// processes that need it (the server, and a `kaiba --jwt ...` invocation) are
// exactly the processes that already open the store, so there is nothing extra
// to distribute, and a key that is never written to a dotfile cannot be leaked
// by copying one.

public extension NoteService {
  static let jwtSigningSecretSettingKey = "auth.jwt.secret"

  /// The store's signing key, generated on first use.
  func authTokenSigningSecret() throws -> Data {
    let key = try Self.normalizedSettingKey(Self.jwtSigningSecretSettingKey, allowReserved: true)
    return try driver.withDatabase { database in
      try database.transaction { db in
        if let stored = try storedAuthTokenSigningSecret(key: key, in: db) {
          return stored
        }
        let candidate = try randomSecret(byteCount: 32)
        guard let encoded = String(
          data: try JSONEncoder().encode(KaibaJWT.base64URLEncode(candidate)),
          encoding: .utf8
        ) else {
          throw NoteServiceError.invalidInput("could not encode the signing secret")
        }
        // Keep a first issuer's signing key canonical. Concurrent processes
        // may generate different candidates, but only the stored winner may
        // sign a token that callers receive.
        try db.execute(
          """
          INSERT INTO app_settings (setting_key, value_json, updated_at)
          VALUES (?, jsonb(?), ?)
          ON CONFLICT(setting_key) DO NOTHING
          """,
          bindings: [.text(key), .text(encoded), .text(NoteStoreClock.system.now())]
        )
        guard let stored = try storedAuthTokenSigningSecret(key: key, in: db) else {
          throw NoteServiceError.invalidInput("stored signing secret is invalid")
        }
        return stored
      }
    }
  }

  /// Mints a token for a user as an enabled administrator or local operator.
  /// The user must exist and be enabled, so a disabled account cannot be
  /// handed a fresh credential.
  func issueAuthToken(
    userId: UserID,
    ttlSeconds: Int = KaibaJWT.defaultTTLSeconds
  ) throws -> String {
    // Refuse before generating the store secret: a rejected scoped request
    // must not get to initialize control-plane state. The transaction below
    // repeats the check so demotion or disablement cannot race the mint.
    try driver.withDatabase { database in
      try requireStoreAdministrator(in: database)
    }
    let secret = try authTokenSigningSecret()
    return try driver.withDatabase { database in
      try database.transaction { db in
        try requireStoreAdministrator(in: db)
        return try issueVerifiedAuthToken(
          userId: userId,
          ttlSeconds: ttlSeconds,
          secret: secret,
          in: db
        )
      }
    }
  }

  func issueAgentToken(userId: UserID, ttlSeconds: Int) throws -> KaibaAgentTokenIssue {
    do {
      let secret = try authTokenSigningSecret()
      let token = try driver.withDatabase { database in
        guard let user = try userRow(id: userId, in: database).map(noteUser(from:)), user.isEnabled else {
          throw KaibaAgentTokenIssuingError.accountUnavailable
        }
        return try KaibaJWT.sign(
          subject: user.userId.rawValue,
          secret: secret,
          ttlSeconds: ttlSeconds
        )
      }
      let claims = try KaibaJWT.verify(token, secret: secret)
      return KaibaAgentTokenIssue(token: token, expiresAt: claims.expiresAt)
    } catch let error as KaibaAgentTokenIssuingError {
      throw error
    } catch {
      throw KaibaAgentTokenIssuingError.operationFailed
    }
  }

  /// Verifies a token and returns the account it acts as. Signature and expiry
  /// are checked first, then the account itself: a token for a user who has
  /// since been disabled is refused even though it is still well-formed.
  func resolveAuthToken(_ token: String) throws -> NoteUser {
    let claims = try KaibaJWT.verify(token, secret: try authTokenSigningSecret())
    guard let user = try storedUser(id: UserID(claims.subject)) else {
      throw NoteServiceError.notFound("user not found: \(claims.subject)")
    }
    guard user.isEnabled else {
      throw NoteServiceError.invalidInput("user is disabled: \(user.userId)")
    }
    return user
  }

  private func randomSecret(byteCount: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    #if canImport(Security)
    guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
      throw NoteServiceError.invalidInput("secure random generation failed")
    }
    #else
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    #endif
    return Data(bytes)
  }

  private func storedAuthTokenSigningSecret(key: String, in database: SQLiteDatabase) throws -> Data? {
    guard let stored = try database.query(
      "SELECT json(value_json) AS value_json FROM app_settings WHERE setting_key = ? LIMIT 1",
      bindings: [.text(key)]
    ).first?["value_json"],
      let value = try? JSONDecoder().decode(String.self, from: Data(stored.utf8)),
      let secret = KaibaJWT.base64URLDecode(value),
      secret.count >= 32 else {
      return nil
    }
    return secret
  }
}

extension NoteService {
  /// The email-login flow has already authenticated its user with a consumed
  /// one-time code. Keep this module-internal path separate from the public
  /// operator-only token issue endpoint.
  func issueVerifiedAuthToken(userId: UserID, ttlSeconds: Int) throws -> String {
    let secret = try authTokenSigningSecret()
    return try driver.withDatabase { database in
      try issueVerifiedAuthToken(userId: userId, ttlSeconds: ttlSeconds, secret: secret, in: database)
    }
  }

  func issueVerifiedAuthToken(
    userId: UserID,
    ttlSeconds: Int,
    secret: Data,
    in database: SQLiteDatabase
  ) throws -> String {
    let user = try requireUser(userId, in: database)
    guard user.isEnabled else {
      throw NoteServiceError.invalidInput("user is disabled: \(userId)")
    }
    return try KaibaJWT.sign(subject: user.userId.rawValue, secret: secret, ttlSeconds: ttlSeconds)
  }
}

extension NoteService: KaibaAgentTokenIssuing {}
