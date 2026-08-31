import Foundation
@testable import AppCore
import XCTest

// The credential that travels between processes: the server mints it, an agent
// carries it, and `kaiba --jwt` resolves the acting user from it
// (`design-docs/specs/note-api-auth.md`).

final class KaibaJWTTests: XCTestCase {
  private let secret = Data(repeating: 7, count: 32)

  func testRoundTripCarriesTheSubject() throws {
    let token = try KaibaJWT.sign(subject: "user-alice", secret: secret)

    let claims = try KaibaJWT.verify(token, secret: secret)
    XCTAssertEqual(claims.subject, "user-alice")
    XCTAssertEqual(claims.issuer, KaibaJWT.issuer)
    XCTAssertFalse(claims.tokenId.isEmpty)
    XCTAssertEqual(claims.expiresAt - claims.issuedAt, KaibaJWT.defaultTTLSeconds)
  }

  func testAnotherKeyCannotVerify() throws {
    let token = try KaibaJWT.sign(subject: "user-alice", secret: secret)

    XCTAssertThrowsError(try KaibaJWT.verify(token, secret: Data(repeating: 8, count: 32))) { error in
      XCTAssertEqual(error as? KaibaJWTError, .signatureMismatch)
    }
  }

  func testTamperedPayloadIsRejected() throws {
    let token = try KaibaJWT.sign(subject: "user-alice", secret: secret)
    var segments = token.split(separator: ".").map(String.init)
    let forgedPayload = try JSONValue.object([
      "sub": .string("user-bob"),
      "iss": .string("kaiba"),
      "iat": .integer(1),
      "exp": .integer(9_999_999_999),
      "jti": .string("x")
    ]).encodedData()
    segments[1] = KaibaJWT.base64URLEncode(forgedPayload)

    XCTAssertThrowsError(try KaibaJWT.verify(segments.joined(separator: "."), secret: secret)) { error in
      XCTAssertEqual(error as? KaibaJWTError, .signatureMismatch)
    }
  }

  func testExpiredTokenIsRejectedBeyondTheSkewWindow() throws {
    let issuedAt = Date(timeIntervalSince1970: 1_000_000)
    let token = try KaibaJWT.sign(
      subject: "user-alice",
      secret: secret,
      ttlSeconds: 60,
      issuedAt: issuedAt
    )

    // Inside the skew window it still verifies; well past it, it does not.
    XCTAssertNoThrow(try KaibaJWT.verify(token, secret: secret, now: issuedAt.addingTimeInterval(90)))
    XCTAssertThrowsError(try KaibaJWT.verify(token, secret: secret, now: issuedAt.addingTimeInterval(600)))
  }

  func testMalformedTokensAreRejected() {
    XCTAssertThrowsError(try KaibaJWT.verify("not-a-token", secret: secret))
    XCTAssertThrowsError(try KaibaJWT.verify("a.b", secret: secret))
    XCTAssertThrowsError(try KaibaJWT.verify("", secret: secret))
  }

  func testSigningRefusesAnEmptySubject() {
    XCTAssertThrowsError(try KaibaJWT.sign(subject: "", secret: secret))
  }
}

final class NoteServiceAuthTokenTests: NoteTestCase {
  func testIssuedTokenResolvesBackToItsUser() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let token = try service.issueAuthToken(userId: alice.userId)

    XCTAssertEqual(try service.resolveAuthToken(token).userId, alice.userId)
  }

  func testTheSigningSecretIsStableAcrossCalls() throws {
    let service = try makeService()

    XCTAssertEqual(try service.authTokenSigningSecret(), try service.authTokenSigningSecret())
    XCTAssertEqual(try service.authTokenSigningSecret().count, 32)
  }

  func testTokensForUnknownOrDisabledUsersAreRefused() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let token = try service.issueAuthToken(userId: alice.userId)

    XCTAssertThrowsError(try service.issueAuthToken(userId: UserID("user-nobody")))
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)
    // A token stays well-formed after the account is disabled; resolving it is
    // what must fail, so revoking access does not depend on token expiry.
    XCTAssertThrowsError(try service.resolveAuthToken(token))
  }

  func testScopedNonAdminCannotIssueAnAuthenticationToken() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    XCTAssertThrowsError(
      try service.scoped(to: alice.userId).issueAuthToken(userId: NoteStoreSchema.defaultUserId)
    ) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("control-plane resource not found"))
    }
  }

  func testAgentTokenIssuanceClassifiesDisabledAccounts() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)

    XCTAssertThrowsError(try service.issueAgentToken(userId: alice.userId, ttlSeconds: 300)) { error in
      XCTAssertEqual(error as? KaibaAgentTokenIssuingError, .accountUnavailable)
    }
  }

  func testAgentTokenIssuanceForAnEnabledAccountProducesAResolvableJWT() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let issue = try service.issueAgentToken(userId: alice.userId, ttlSeconds: 300)
    let claims = try KaibaJWT.verify(issue.token, secret: service.authTokenSigningSecret())

    XCTAssertEqual(try service.resolveAuthToken(issue.token).userId, alice.userId)
    XCTAssertEqual(claims.subject, alice.userId.rawValue)
    XCTAssertEqual(claims.expiresAt - claims.issuedAt, 300)
    XCTAssertEqual(issue.expiresAt, claims.expiresAt)
  }

  func testConcurrentAgentTokenIssuanceUsesOneCanonicalSigningSecret() async throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let issues = try await withThrowingTaskGroup(of: KaibaAgentTokenIssue.self) { group in
      for _ in 0..<32 {
        group.addTask {
          try service.issueAgentToken(userId: alice.userId, ttlSeconds: 300)
        }
      }
      var collected: [KaibaAgentTokenIssue] = []
      for try await issue in group {
        collected.append(issue)
      }
      return collected
    }

    XCTAssertEqual(issues.count, 32)
    for issue in issues {
      XCTAssertEqual(try service.resolveAuthToken(issue.token).userId, alice.userId)
    }
  }

  func testATokenFromAnotherStoreIsRefused() throws {
    let service = try makeService()
    let other = try makeService(function: "otherStoreForTokenIsolation")
    let user = try other.createUser(email: "alice@example.com", displayName: "Alice")
    let foreignToken = try other.issueAuthToken(userId: user.userId)

    XCTAssertThrowsError(try service.resolveAuthToken(foreignToken))
  }
}
