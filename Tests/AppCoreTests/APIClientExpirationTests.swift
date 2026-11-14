import Foundation
@testable import AppCore
import XCTest

final class APIClientExpirationTests: NoteTestCase {
  func testExpirationIncludesEntireUTCDayAndDoesNotRecordExpiredRequests() throws {
    let service = try makeService()
    let key = "date-boundary-key"
    let client = try service.registerAPIClient(displayName: "Boundary", bearerToken: key, expiresAt: "2027-12-31")
    let lastMoment = try timestamp("2027-12-31T23:59:59.999Z")
    XCTAssertEqual(try service.authenticateAPIClient(bearerToken: key, at: lastMoment)?.clientId, client.clientId)
    let lastSeen = try XCTUnwrap(service.listAPIClients().first?.lastSeenAt)
    XCTAssertNil(try service.authenticateAPIClient(bearerToken: key, at: timestamp("2028-01-01T00:00:00.000Z")))
    XCTAssertEqual(try service.listAPIClients().first?.lastSeenAt, lastSeen)
    XCTAssertEqual(try service.listAPIClients().first?.expiresAt, "2027-12-31")
  }

  func testNeverStillHonorsRevocationAndDisabledAccounts() throws {
    let service = try makeService()
    let future = try timestamp("2099-01-01T00:00:00.000Z")
    let user = try service.createUser(email: "key-owner@example.com", displayName: "Owner")
    let client = try service.registerAPIClient(displayName: "Permanent", bearerToken: "permanent", userId: user.userId)
    XCTAssertNil(client.expiresAt)
    XCTAssertEqual(try service.authenticateAPIClient(bearerToken: "permanent", at: future)?.clientId, client.clientId)
    _ = try service.setUserDisabled(userId: user.userId, disabled: true)
    XCTAssertNil(try service.authenticateAPIClient(bearerToken: "permanent", at: future))
    _ = try service.setUserDisabled(userId: user.userId, disabled: false)
    _ = try service.revokeAPIClient(clientId: client.clientId)
    XCTAssertNil(try service.authenticateAPIClient(bearerToken: "permanent", at: future))
  }

  func testServiceRejectsNonCanonicalAndInvalidCalendarDatesWithoutIssuingKeys() throws {
    let service = try makeService()
    for invalid in ["", "never", "2027-+1-01", "2027-02-29", "2028-02-30", "2028-00-01", "0000-01-01", "2028-1-01", "2028-01-01T00:00:00Z"] {
      XCTAssertThrowsError(try service.registerAPIClient(displayName: "Invalid", bearerToken: invalid, expiresAt: invalid))
    }
    XCTAssertTrue(try service.listAPIClients().isEmpty)
    XCTAssertEqual(
      try service.registerAPIClient(displayName: "Leap day", bearerToken: "leap", expiresAt: "2028-02-29").expiresAt,
      "2028-02-29"
    )
  }

  private func timestamp(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try XCTUnwrap(formatter.date(from: value))
  }
}
