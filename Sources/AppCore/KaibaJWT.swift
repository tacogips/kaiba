import CryptoKit
import Foundation

// HS256 JSON Web Tokens, used as the credential that travels between processes:
// the server hands one to an agent, and the agent passes it to `kaiba --jwt`,
// which resolves the acting user from it (`design-docs/specs/note-api-auth.md`).
//
// HMAC rather than a public-key algorithm because both ends are the same
// installation sharing one store: there is no third party to verify without the
// signing key, and a symmetric key needs no rotation ceremony to be safe here.
// Externally issued tokens (Auth0) are a separate, later verification path.

public enum KaibaJWTError: Error, Equatable, Sendable, CustomStringConvertible {
  case malformed(String)
  case unsupportedAlgorithm(String)
  case signatureMismatch
  case expired(at: Int)
  case notYetValid(at: Int)
  case issuerMismatch(String)
  case missingClaim(String)

  public var description: String {
    switch self {
    case let .malformed(detail): "token is malformed: \(detail)"
    case let .unsupportedAlgorithm(algorithm): "unsupported token algorithm: \(algorithm)"
    case .signatureMismatch: "token signature does not match"
    case let .expired(at): "token expired at \(at)"
    case let .notYetValid(at): "token is not valid until \(at)"
    case let .issuerMismatch(issuer): "token was issued by \(issuer)"
    case let .missingClaim(name): "token is missing the \(name) claim"
    }
  }
}

public struct KaibaJWTClaims: Equatable, Sendable {
  /// The account the bearer acts as.
  public var subject: String
  public var issuer: String
  public var issuedAt: Int
  public var expiresAt: Int
  /// Token identity, so a specific token can be denied without rotating the
  /// signing key.
  public var tokenId: String

  public init(subject: String, issuer: String, issuedAt: Int, expiresAt: Int, tokenId: String) {
    self.subject = subject
    self.issuer = issuer
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.tokenId = tokenId
  }
}

public enum KaibaJWT {
  public static let issuer = "kaiba"
  public static let defaultTTLSeconds = 3600
  /// Tolerated clock difference between the signing and verifying processes.
  public static let clockSkewSeconds = 60

  public static func sign(
    subject: String,
    secret: Data,
    ttlSeconds: Int = defaultTTLSeconds,
    issuedAt: Date = Date(),
    tokenId: String = UUID().uuidString
  ) throws -> String {
    guard !subject.isEmpty else {
      throw KaibaJWTError.missingClaim("sub")
    }
    guard ttlSeconds > 0 else {
      throw KaibaJWTError.malformed("token lifetime must be positive")
    }
    let issued = Int(issuedAt.timeIntervalSince1970)
    let header: JSONObject = ["alg": .string("HS256"), "typ": .string("JWT")]
    let payload: JSONObject = [
      "sub": .string(subject),
      "iss": .string(issuer),
      "iat": .integer(Int64(issued)),
      "exp": .integer(Int64(issued + ttlSeconds)),
      "jti": .string(tokenId)
    ]
    let signingInput = "\(try encodeSegment(header)).\(try encodeSegment(payload))"
    return "\(signingInput).\(base64URLEncode(signature(for: signingInput, secret: secret)))"
  }

  public static func verify(
    _ token: String,
    secret: Data,
    now: Date = Date()
  ) throws -> KaibaJWTClaims {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else {
      throw KaibaJWTError.malformed("expected three dot-separated segments")
    }
    let signingInput = "\(segments[0]).\(segments[1])"
    guard let providedSignature = base64URLDecode(String(segments[2])) else {
      throw KaibaJWTError.malformed("signature is not base64url")
    }
    // Constant-time: a byte-by-byte early return would leak the signature.
    guard HMAC<SHA256>.isValidAuthenticationCode(
      providedSignature,
      authenticating: Data(signingInput.utf8),
      using: SymmetricKey(data: secret)
    ) else {
      throw KaibaJWTError.signatureMismatch
    }

    let header = try decodeSegment(String(segments[0]), name: "header")
    guard let algorithm = header["alg"]?.asString else {
      throw KaibaJWTError.missingClaim("alg")
    }
    guard algorithm == "HS256" else {
      throw KaibaJWTError.unsupportedAlgorithm(algorithm)
    }
    let payload = try decodeSegment(String(segments[1]), name: "payload")
    guard let subject = payload["sub"]?.asString, !subject.isEmpty else {
      throw KaibaJWTError.missingClaim("sub")
    }
    guard let tokenIssuer = payload["iss"]?.asString else {
      throw KaibaJWTError.missingClaim("iss")
    }
    guard tokenIssuer == issuer else {
      throw KaibaJWTError.issuerMismatch(tokenIssuer)
    }
    guard let issuedAt = payload["iat"]?.asInt else {
      throw KaibaJWTError.missingClaim("iat")
    }
    guard let expiresAt = payload["exp"]?.asInt else {
      throw KaibaJWTError.missingClaim("exp")
    }
    let current = Int(now.timeIntervalSince1970)
    guard current <= expiresAt + clockSkewSeconds else {
      throw KaibaJWTError.expired(at: expiresAt)
    }
    guard current >= issuedAt - clockSkewSeconds else {
      throw KaibaJWTError.notYetValid(at: issuedAt)
    }
    guard let tokenId = payload["jti"]?.asString else {
      throw KaibaJWTError.missingClaim("jti")
    }
    return KaibaJWTClaims(
      subject: subject,
      issuer: tokenIssuer,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      tokenId: tokenId
    )
  }

  private static func signature(for signingInput: String, secret: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(
      for: Data(signingInput.utf8),
      using: SymmetricKey(data: secret)
    ))
  }

  private static func encodeSegment(_ object: JSONObject) throws -> String {
    base64URLEncode(try JSONValue.object(object).encodedData())
  }

  /// Segments decode into `JSONValue`, so a claim of the wrong shape reads as
  /// a missing claim instead of an unchecked `Any` cast.
  private static func decodeSegment(_ segment: String, name: String) throws -> JSONValue {
    guard let data = base64URLDecode(segment) else {
      throw KaibaJWTError.malformed("\(name) is not base64url")
    }
    guard let value = try? JSONValue(parsing: data), value.asObject != nil else {
      throw KaibaJWTError.malformed("\(name) is not a JSON object")
    }
    return value
  }

  static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func base64URLDecode(_ value: String) -> Data? {
    var normalized = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: normalized)
  }
}
