import Foundation
@testable import AppCore
import XCTest

// Passwordless email login (`design-docs/specs/note-api-auth.md`): a code is
// mailed to an address that already has an account, and verifying it yields the
// same token the CLI and the agent hand-off use.

private final class RecordingMailSender: KaibaMailSending, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [KaibaMailMessage] = []
  var failure: (any Error)?

  var messages: [KaibaMailMessage] {
    lock.lock()
    defer { lock.unlock() }
    return sent
  }

  func send(_ message: KaibaMailMessage) async throws {
    if let failure {
      throw failure
    }
    record(message)
  }

  private func record(_ message: KaibaMailMessage) {
    lock.lock()
    defer { lock.unlock() }
    sent.append(message)
  }
}

final class EmailLoginTests: NoteTestCase {
  func testCodeRoundTripYieldsAWorkingToken() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let challenge = try XCTUnwrap(try service.requestEmailLoginCode(email: "alice@example.com"))
    XCTAssertEqual(challenge.userId, alice.userId)
    XCTAssertEqual(challenge.code.count, 6)
    XCTAssertTrue(challenge.code.allSatisfy(\.isNumber))

    let token = try service.verifyEmailLoginCode(email: "alice@example.com", code: challenge.code)
    XCTAssertEqual(try service.resolveAuthToken(token).userId, alice.userId)
  }

  func testTheAddressIsMatchedCaseInsensitively() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")

    let challenge = try XCTUnwrap(try service.requestEmailLoginCode(email: "ALICE@Example.com "))
    XCTAssertNoThrow(try service.verifyEmailLoginCode(email: "Alice@example.com", code: challenge.code))
  }

  func testACodeWorksOnlyOnce() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let challenge = try XCTUnwrap(try service.requestEmailLoginCode(email: "alice@example.com"))

    _ = try service.verifyEmailLoginCode(email: "alice@example.com", code: challenge.code)
    XCTAssertThrowsError(
      try service.verifyEmailLoginCode(email: "alice@example.com", code: challenge.code)
    ) { error in
      XCTAssertEqual(error as? KaibaEmailLoginError, .invalidCode)
    }
  }

  func testAnExpiredCodeIsRefused() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let issuedAt = Date()
    let challenge = try XCTUnwrap(
      try service.requestEmailLoginCode(email: "alice@example.com", ttlSeconds: 60, now: issuedAt)
    )

    XCTAssertThrowsError(
      try service.verifyEmailLoginCode(
        email: "alice@example.com",
        code: challenge.code,
        now: issuedAt.addingTimeInterval(120)
      )
    )
  }

  func testGuessingIsBoundedByTheAttemptCap() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let challenge = try XCTUnwrap(try service.requestEmailLoginCode(email: "alice@example.com"))
    let wrongCode = challenge.code == "000000" ? "111111" : "000000"

    for _ in 0..<NoteService.emailLoginCodeMaximumAttempts {
      XCTAssertThrowsError(try service.verifyEmailLoginCode(email: "alice@example.com", code: wrongCode))
    }
    // The real code is dead too: the cap bounds guessing against the code, not
    // against one guesser.
    XCTAssertThrowsError(
      try service.verifyEmailLoginCode(email: "alice@example.com", code: challenge.code)
    )
  }

  func testRequestingIsRateLimitedPerAccount() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")

    for _ in 0..<NoteService.emailLoginCodeMaximumLive {
      XCTAssertNotNil(try service.requestEmailLoginCode(email: "alice@example.com"))
    }
    XCTAssertThrowsError(try service.requestEmailLoginCode(email: "alice@example.com")) { error in
      guard case .rateLimited = error as? KaibaEmailLoginError else {
        return XCTFail("expected a rate-limit error, got \(error)")
      }
    }
  }

  func testUnknownAndDisabledAddressesMintNothing() throws {
    let service = try makeService()
    let alice = try service.createUser(email: "alice@example.com", displayName: "Alice")

    XCTAssertNil(try service.requestEmailLoginCode(email: "nobody@example.com"))
    XCTAssertNil(try service.requestEmailLoginCode(email: "not-an-address"))
    _ = try service.setUserDisabled(userId: alice.userId, disabled: true)
    XCTAssertNil(try service.requestEmailLoginCode(email: "alice@example.com"))
  }

  func testDeliveryCarriesTheCodeAndSkipsUnknownAddresses() async throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let sender = RecordingMailSender()

    let deliveredToKnown = try await service.sendEmailLoginCode(
      email: "alice@example.com",
      mailSender: sender,
      fromAddress: "kaiba@example.com"
    )
    let deliveredToUnknown = try await service.sendEmailLoginCode(
      email: "nobody@example.com",
      mailSender: sender,
      fromAddress: "kaiba@example.com"
    )

    XCTAssertTrue(deliveredToKnown)
    XCTAssertFalse(deliveredToUnknown)
    XCTAssertEqual(sender.messages.count, 1)
    let message = try XCTUnwrap(sender.messages.first)
    XCTAssertEqual(message.to, "alice@example.com")
    XCTAssertEqual(message.from, "kaiba@example.com")
    XCTAssertNotNil(message.idempotencyKey)

    // The mailed code is the one that verifies.
    let mailedCode = try XCTUnwrap(
      message.text
        .split(whereSeparator: { $0.isWhitespace })
        .first { $0.count == 6 && $0.allSatisfy(\.isNumber) }
    )
    XCTAssertNoThrow(
      try service.verifyEmailLoginCode(email: "alice@example.com", code: String(mailedCode))
    )
  }

  func testStoredCodesAreHashedNotPlaintext() throws {
    let service = try makeService()
    _ = try service.createUser(email: "alice@example.com", displayName: "Alice")
    let challenge = try XCTUnwrap(try service.requestEmailLoginCode(email: "alice@example.com"))

    let stored = try service.driver.withDatabase { database in
      try database.query("SELECT code_hash FROM auth_login_codes").compactMap { $0["code_hash"] }
    }
    XCTAssertEqual(stored.count, 1)
    XCTAssertFalse(stored.contains(challenge.code))
    XCTAssertEqual(stored.first?.count, 64)
  }
}

final class ResendGatewayCLIMailSenderTests: XCTestCase {
  func testAMissingBinaryIsReportedAsUnavailable() {
    let sender = ResendGatewayCLIMailSender(
      commandPath: "/nonexistent/resend-gateway-writer",
      environment: [:]
    )

    XCTAssertFalse(sender.isAvailable)
    XCTAssertThrowsError(try sender.resolveBinary()) { error in
      guard case .unavailable = error as? KaibaMailError else {
        return XCTFail("expected an unavailable error, got \(error)")
      }
    }
  }

  func testANonZeroExitBecomesADeliveryFailure() async {
    let sender = ResendGatewayCLIMailSender(commandPath: "/usr/bin/false", environment: [:])

    do {
      try await sender.send(KaibaMailMessage(
        to: "someone@example.com",
        from: "kaiba@example.com",
        subject: "s",
        text: "t"
      ))
      XCTFail("expected delivery to fail")
    } catch {
      guard case .failed = error as? KaibaMailError else {
        return XCTFail("expected a delivery failure, got \(error)")
      }
    }
  }
}
