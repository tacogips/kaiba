import XCTest

@testable import AppCore

/// Authorization boundaries that are not tied to library reach: the reserved
/// app-settings namespace that hides the JWT signing key, and the admin gate on
/// store-wide file maintenance.
final class NoteServiceSecurityTests: NoteTestCase {

  // MARK: - Reserved app-settings namespace (JWT signing key)

  func testReservedAuthSettingKeyIsNotReadableThroughAppSetting() throws {
    let service = try NoteService(driver: makeNoteDriver())
    // Force the signing key into existence.
    _ = try service.authTokenSigningSecret()

    XCTAssertThrowsError(try service.appSetting(key: NoteService.jwtSigningSecretSettingKey)) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput(
        "setting key must be 1-64 letters, numbers, '-' or '.'"
      ))
    }
    XCTAssertThrowsError(try service.appSetting(key: "auth.anything"))
  }

  func testReservedAuthSettingKeyIsNotWritableThroughSetAppSetting() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let firstSecret = try service.authTokenSigningSecret()

    XCTAssertThrowsError(
      try service.setAppSetting(key: NoteService.jwtSigningSecretSettingKey, valueJSON: "\"forged\"")
    )
    // The write was refused, so the key the store signs with is unchanged.
    XCTAssertEqual(try service.authTokenSigningSecret(), firstSecret)
  }

  func testOrdinarySettingKeysStillWork() throws {
    let service = try NoteService(driver: makeNoteDriver())
    _ = try service.setAppSetting(key: "web", valueJSON: "{\"fontScale\":1.2}")
    XCTAssertEqual(try service.appSetting(key: "web"), "{\"fontScale\":1.2}")
  }

  // MARK: - Admin gate on store-wide file maintenance

  func testReclaimUnreferencedFilesRefusedForNonAdminClient() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let outsider = try service.createUser(email: "outsider@example.com", displayName: "Outsider")
    let scoped = service.scoped(to: outsider.userId)

    XCTAssertThrowsError(try scoped.reclaimUnreferencedFiles(olderThan: 0)) { error in
      XCTAssertEqual(error as? NoteServiceError, .invalidInput(
        "this operation requires an administrator account"
      ))
    }
  }

  func testReclaimUnreferencedFilesAllowedForUnscopedOperator() throws {
    let service = try NoteService(driver: makeNoteDriver())
    // The unscoped CLI operator holds the store file; the pass must run.
    XCTAssertNoThrow(try service.reclaimUnreferencedFiles(olderThan: 0))
  }

  func testReclaimUnreferencedFilesAllowedForAdminClient() throws {
    let service = try NoteService(driver: makeNoteDriver())
    let admin = try service.createUser(email: "admin@example.com", displayName: "Admin", isAdmin: true)
    let scoped = service.scoped(to: admin.userId)
    XCTAssertNoThrow(try scoped.reclaimUnreferencedFiles(olderThan: 0))
  }
}
