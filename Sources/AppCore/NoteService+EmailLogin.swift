import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

// Passwordless email login (`design-docs/specs/note-api-auth.md`). A short code
// is mailed to an address that already has an enabled account; verifying it
// yields the same JWT the CLI and the agent hand-off use.
//
// There is no password anywhere in this flow, which is the point: nothing to
// hash with a KDF that neither CryptoKit nor swift-crypto ships portably, and
// nothing to reset, breach, or reuse from another site.

/// A code that has been minted and stored, waiting to be delivered. The
/// plaintext exists only in memory, on its way to the mail sender.
public struct KaibaEmailLoginChallenge: Equatable, Sendable {
  public var userId: UserID
  public var email: String
  public var code: String
  public var expiresAt: String

  public init(userId: UserID, email: String, code: String, expiresAt: String) {
    self.userId = userId
    self.email = email
    self.code = code
    self.expiresAt = expiresAt
  }
}

public enum KaibaEmailLoginError: Error, Equatable, Sendable, CustomStringConvertible {
  case rateLimited(retryAfterSeconds: Int)
  case invalidCode
  case tooManyAttempts

  public var description: String {
    switch self {
    // Deliberately uniform wording for every wrong, expired, consumed or
    // never-issued code: distinguishing them tells an attacker which addresses
    // have accounts and which codes are live.
    case .invalidCode: "that code is not valid"
    case .tooManyAttempts: "that code is not valid"
    case let .rateLimited(retryAfter): "too many login requests; retry in \(retryAfter) seconds"
    }
  }
}

/// Why a verification ended, carried out of the transaction so the failure
/// bookkeeping commits before the caller sees an error.
enum LoginCodeOutcome: Equatable, Sendable {
  case accepted
  case rejected
  case exhausted
}

public extension NoteService {
  static let emailLoginCodeTTLSeconds = 600
  static let emailLoginCodeMaximumAttempts = 5
  /// Live codes one account may hold at once. A sixth request inside the TTL is
  /// refused rather than queued, so requesting cannot be used to flood an inbox.
  static let emailLoginCodeMaximumLive = 3

  /// Mints a login code for an address, or returns nil when no enabled account
  /// has it. Callers must answer identically in both cases — the nil is for
  /// deciding whether to send mail, never for telling the requester.
  func requestEmailLoginCode(
    email: String,
    ttlSeconds: Int = emailLoginCodeTTLSeconds,
    now: Date = Date()
  ) throws -> KaibaEmailLoginChallenge? {
    guard let normalizedEmail = (try? normalizedUserEmail(email)) ?? nil,
          let user = try user(email: normalizedEmail),
          user.isEnabled else {
      return nil
    }
    let code = try makeLoginCode()
    let expiresAt = noteStoreTimestamp(from: now.addingTimeInterval(TimeInterval(ttlSeconds)))
    let issuedAt = noteStoreTimestamp(from: now)
    try driver.withDatabase { database in
      try database.transaction { db in
        try pruneExpiredLoginCodes(now: issuedAt, in: db)
        let live = try db.query(
          """
          SELECT count(*) AS live
          FROM auth_login_codes
          WHERE user_id = ? AND consumed_at IS NULL AND expires_at > ?
          """,
          bindings: [.id(user.userId), .text(issuedAt)]
        ).first?["live"].flatMap(Int.init) ?? 0
        guard live < Self.emailLoginCodeMaximumLive else {
          throw KaibaEmailLoginError.rateLimited(retryAfterSeconds: ttlSeconds)
        }
        try db.execute(
          """
          INSERT INTO auth_login_codes (
            code_id, user_id, code_hash, attempts, created_at, expires_at, consumed_at
          ) VALUES (?, ?, ?, 0, ?, ?, NULL)
          """,
          bindings: [
            .text(makeOpaqueToken(prefix: "logincode")),
            .id(user.userId),
            .text(Self.loginCodeHash(userId: user.userId, code: code)),
            .text(issuedAt),
            .text(expiresAt)
          ]
        )
      }
    }
    return KaibaEmailLoginChallenge(
      userId: user.userId,
      email: normalizedEmail,
      code: code,
      expiresAt: expiresAt
    )
  }

  /// Consumes a code and returns a token for the account. Single use: the row
  /// is marked consumed inside the same transaction that accepts it, so two
  /// racing verifications cannot both succeed.
  func verifyEmailLoginCode(
    email: String,
    code: String,
    ttlSeconds: Int = KaibaJWT.defaultTTLSeconds,
    now: Date = Date()
  ) throws -> String {
    guard let normalizedEmail = (try? normalizedUserEmail(email)) ?? nil,
          let user = try user(email: normalizedEmail),
          user.isEnabled else {
      throw KaibaEmailLoginError.invalidCode
    }
    let submitted = code.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestamp = noteStoreTimestamp(from: now)
    let hash = Self.loginCodeHash(userId: user.userId, code: submitted)
    // The verdict is returned from the transaction, not thrown out of it:
    // throwing rolls the transaction back, which would discard the attempt
    // counter that bounds guessing — the whole reason for recording it.
    let outcome = try driver.withDatabase { database in
      try database.transaction { db -> LoginCodeOutcome in
        let rows = try db.query(
          """
          SELECT code_id, code_hash, attempts
          FROM auth_login_codes
          WHERE user_id = ? AND consumed_at IS NULL AND expires_at > ?
          ORDER BY created_at DESC
          """,
          bindings: [.id(user.userId), .text(timestamp)]
        )
        guard let match = rows.first(where: { $0["code_hash"] == hash }) else {
          // A wrong guess burns an attempt on every live code, so guessing is
          // bounded even when several are outstanding.
          try db.execute(
            """
            UPDATE auth_login_codes
            SET attempts = attempts + 1
            WHERE user_id = ? AND consumed_at IS NULL AND expires_at > ?
            """,
            bindings: [.id(user.userId), .text(timestamp)]
          )
          try consumeExhaustedLoginCodes(userId: user.userId, now: timestamp, in: db)
          return .rejected
        }
        let attempts = match["attempts"].flatMap(Int.init) ?? 0
        guard attempts < Self.emailLoginCodeMaximumAttempts else {
          return .exhausted
        }
        guard let codeId = match["code_id"] else {
          throw NoteServiceError.invalidRow("login code row is missing code_id")
        }
        try db.execute(
          "UPDATE auth_login_codes SET consumed_at = ? WHERE code_id = ? AND consumed_at IS NULL",
          bindings: [.text(timestamp), .text(codeId)]
        )
        try pruneExpiredLoginCodes(now: timestamp, in: db)
        return .accepted
      }
    }
    switch outcome {
    case .accepted:
      return try issueAuthToken(userId: user.userId, ttlSeconds: ttlSeconds)
    case .rejected:
      throw KaibaEmailLoginError.invalidCode
    case .exhausted:
      throw KaibaEmailLoginError.tooManyAttempts
    }
  }

  /// Mints a code, delivers it, and reports whether mail went out. Delivery
  /// failure is not hidden from the operator, but the caller of a public login
  /// endpoint must still answer identically either way.
  func sendEmailLoginCode(
    email: String,
    mailSender: any KaibaMailSending,
    fromAddress: String,
    ttlSeconds: Int = emailLoginCodeTTLSeconds,
    now: Date = Date()
  ) async throws -> Bool {
    guard let challenge = try requestEmailLoginCode(email: email, ttlSeconds: ttlSeconds, now: now) else {
      return false
    }
    let minutes = max(1, ttlSeconds / 60)
    try await mailSender.send(KaibaMailMessage(
      to: challenge.email,
      from: fromAddress,
      subject: "Your kaiba sign-in code",
      text: """
        Your kaiba sign-in code is \(challenge.code)

        It expires in \(minutes) minute\(minutes == 1 ? "" : "s") and can be used once.
        If you did not ask to sign in, you can ignore this message.
        """,
      // One delivery per code: a retried request mints a new code and so gets
      // a new key, while a duplicated send of the same code does not.
      idempotencyKey: "kaiba-login-\(Self.loginCodeHash(userId: challenge.userId, code: challenge.code).prefix(32))"
    ))
    return true
  }

  static func loginCodeHash(userId: UserID, code: String) -> String {
    // Salted by the account id: a stolen table of hashes cannot be reversed
    // with one precomputed rainbow table across all users.
    let digest = SHA256.hash(data: Data("\(userId):\(code)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func makeLoginCode() throws -> String {
    // Six digits from rejection-sampled random bytes: an even distribution,
    // and short enough to retype from a phone.
    var digits = ""
    while digits.count < 6 {
      var byte: UInt8 = 0
      #if canImport(Security)
      guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
        throw NoteServiceError.invalidInput("secure random generation failed")
      }
      #else
      byte = UInt8.random(in: UInt8.min...UInt8.max)
      #endif
      if byte < 250 {
        digits.append(String(Int(byte) % 10))
      }
    }
    return digits
  }

  private func pruneExpiredLoginCodes(now: String, in db: SQLiteDatabase) throws {
    try db.execute(
      "DELETE FROM auth_login_codes WHERE expires_at <= ? OR consumed_at IS NOT NULL",
      bindings: [.text(now)]
    )
  }

  private func consumeExhaustedLoginCodes(
    userId: UserID,
    now: String,
    in db: SQLiteDatabase
  ) throws {
    try db.execute(
      """
      UPDATE auth_login_codes
      SET consumed_at = ?
      WHERE user_id = ? AND consumed_at IS NULL AND attempts >= ?
      """,
      bindings: [.text(now), .id(userId), .int(Int64(Self.emailLoginCodeMaximumAttempts))]
    )
  }
}
