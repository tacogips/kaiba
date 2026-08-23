import Foundation
#if canImport(Security)
import Security
#endif

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
    if let stored = try appSetting(key: Self.jwtSigningSecretSettingKey, allowReserved: true),
       let value = try? JSONDecoder().decode(String.self, from: Data(stored.utf8)),
       let secret = KaibaJWT.base64URLDecode(value), secret.count >= 32 {
      return secret
    }
    let secret = try randomSecret(byteCount: 32)
    let encoded = String(
      data: try JSONEncoder().encode(KaibaJWT.base64URLEncode(secret)),
      encoding: .utf8
    )
    guard let encoded else {
      throw NoteServiceError.invalidInput("could not encode the signing secret")
    }
    try setAppSetting(key: Self.jwtSigningSecretSettingKey, valueJSON: encoded, allowReserved: true)
    return secret
  }

  /// Mints a token for a user. The user must exist and be enabled, so a
  /// disabled account cannot be handed a fresh credential.
  func issueAuthToken(
    userId: UserID,
    ttlSeconds: Int = KaibaJWT.defaultTTLSeconds
  ) throws -> String {
    let user = try user(id: userId)
    guard let user else {
      throw NoteServiceError.notFound("user not found: \(userId)")
    }
    guard user.isEnabled else {
      throw NoteServiceError.invalidInput("user is disabled: \(userId)")
    }
    return try KaibaJWT.sign(
      subject: user.userId.rawValue,
      secret: try authTokenSigningSecret(),
      ttlSeconds: ttlSeconds
    )
  }

  /// Verifies a token and returns the account it acts as. Signature and expiry
  /// are checked first, then the account itself: a token for a user who has
  /// since been disabled is refused even though it is still well-formed.
  func resolveAuthToken(_ token: String) throws -> NoteUser {
    let claims = try KaibaJWT.verify(token, secret: try authTokenSigningSecret())
    guard let user = try user(id: UserID(claims.subject)) else {
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
}
