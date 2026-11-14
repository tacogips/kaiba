import Foundation
@testable import AppCore
import XCTest

/// `design-docs/specs/user-agent-tools.md`, UA1/UA2: who may read and write
/// a personal-agent credential, what validation applies, and that the key
/// never leaves through the summary.
final class UserAgentCredentialTests: NoteTestCase {
  private func input(
    provider: UserAgentProvider = .anthropic,
    apiKey: String = "sk-ant-secret-key-9876",
    model: String = "claude-opus-5",
    baseURL: String? = nil,
    enabled: Bool = true
  ) -> UserAgentCredentialInput {
    UserAgentCredentialInput(provider: provider, apiKey: apiKey, defaultModel: model, baseURL: baseURL, enabled: enabled)
  }

  func testOperatorMustNameTheOwnerAndSummaryHidesTheKey() throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")

    XCTAssertThrowsError(try operatorService.setUserAgentCredential(input())) { error in
      guard case NoteServiceError.invalidInput(let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("--user"))
    }

    let summary = try operatorService.setUserAgentCredential(input(), targetUserId: alice.userId)
    XCTAssertEqual(summary.provider, .anthropic)
    XCTAssertEqual(summary.keyHint, "9876")
    XCTAssertEqual(summary.defaultModel, "claude-opus-5")
    XCTAssertTrue(summary.enabled)
    XCTAssertNil(summary.baseURL)
    let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(summary), encoding: .utf8))
    XCTAssertFalse(encoded.contains("sk-ant-secret-key"))

    let stored = try XCTUnwrap(operatorService.storedUserAgentCredential(userId: alice.userId))
    XCTAssertEqual(stored.apiKey, "sk-ant-secret-key-9876")
    XCTAssertEqual(stored.resolvedBaseURL?.absoluteString, "https://api.anthropic.com")
  }

  func testScopedUserReachesOnlyItselfUnlessAdministrator() throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let bob = try operatorService.createUser(email: "bob@example.com", displayName: "Bob")
    let admin = try operatorService.createUser(email: "root@example.com", displayName: "Root", isAdmin: true)
    let aliceService = operatorService.scoped(to: alice.userId)
    let bobService = operatorService.scoped(to: bob.userId)
    let adminService = operatorService.scoped(to: admin.userId)

    _ = try aliceService.setUserAgentCredential(input(model: "alice-model"))
    XCTAssertEqual(try aliceService.userAgentCredentialSummary()?.defaultModel, "alice-model")
    XCTAssertNil(try bobService.userAgentCredentialSummary())

    XCTAssertThrowsError(try bobService.userAgentCredentialSummary(targetUserId: alice.userId)) { error in
      guard case NoteServiceError.notFound = error else {
        return XCTFail("expected notFound, got \(error)")
      }
    }
    XCTAssertThrowsError(try bobService.setUserAgentCredential(input(), targetUserId: alice.userId))

    XCTAssertEqual(
      try adminService.userAgentCredentialSummary(targetUserId: alice.userId)?.defaultModel,
      "alice-model"
    )
    _ = try adminService.setUserAgentCredentialEnabled(false, targetUserId: alice.userId)
    XCTAssertEqual(try aliceService.userAgentCredentialSummary()?.enabled, false)
  }

  func testUnauthenticatedPrincipalIsRefused() throws {
    let operatorService = try makeService()
    let anonymous = operatorService.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    XCTAssertThrowsError(try anonymous.setUserAgentCredential(input())) { error in
      guard case NoteServiceError.notFound = error else {
        return XCTFail("expected notFound, got \(error)")
      }
    }
    XCTAssertThrowsError(try anonymous.userAgentCredentialSummary())
    XCTAssertThrowsError(try anonymous.clearUserAgentCredential())
  }

  func testValidationRejectsBadKeysModelsAndEndpoints() throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let service = operatorService.scoped(to: alice.userId)

    XCTAssertThrowsError(try service.setUserAgentCredential(input(apiKey: "")))
    XCTAssertThrowsError(try service.setUserAgentCredential(input(apiKey: "has space")))
    XCTAssertThrowsError(try service.setUserAgentCredential(input(apiKey: "tab\tkey")))
    XCTAssertThrowsError(try service.setUserAgentCredential(input(model: "   ")))
    XCTAssertThrowsError(try service.setUserAgentCredential(input(provider: .openaiCompatible))) { error in
      guard case NoteServiceError.invalidInput(let message) = error else {
        return XCTFail("expected invalidInput, got \(error)")
      }
      XCTAssertTrue(message.contains("requires baseURL"))
    }
    // Custom endpoints need the operator's permission.
    XCTAssertThrowsError(try service.setUserAgentCredential(
      input(provider: .openai, baseURL: "https://proxy.example.com/v1")
    ))
    XCTAssertThrowsError(try service.setUserAgentCredential(
      input(provider: .openai, baseURL: "ftp://proxy.example.com/v1"),
      customBaseURLAllowed: true
    ))
    XCTAssertThrowsError(try service.setUserAgentCredential(
      input(provider: .openai, baseURL: "https://user:pw@proxy.example.com/v1"),
      customBaseURLAllowed: true
    ))
    let allowed = try service.setUserAgentCredential(
      input(provider: .openaiCompatible, baseURL: " https://proxy.example.com/v1 "),
      customBaseURLAllowed: true
    )
    XCTAssertEqual(allowed.baseURL, "https://proxy.example.com/v1")
    XCTAssertEqual(allowed.provider, .openaiCompatible)
  }

  func testEnableToggleAndClear() throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    let service = operatorService.scoped(to: alice.userId)

    XCTAssertNil(try service.setUserAgentCredentialEnabled(false))
    XCTAssertFalse(try service.clearUserAgentCredential())
    _ = try service.setUserAgentCredential(input())
    XCTAssertEqual(try service.setUserAgentCredentialEnabled(false)?.enabled, false)
    XCTAssertEqual(try service.setUserAgentCredentialEnabled(true)?.enabled, true)
    XCTAssertTrue(try service.clearUserAgentCredential())
    XCTAssertNil(try service.userAgentCredentialSummary())
    XCTAssertNil(try operatorService.storedUserAgentCredential(userId: alice.userId))
  }

  func testDisabledAccountCannotWriteCredential() throws {
    let operatorService = try makeService()
    let alice = try operatorService.createUser(email: "alice@example.com", displayName: "Alice")
    _ = try operatorService.setUserDisabled(userId: alice.userId, disabled: true)
    XCTAssertThrowsError(try operatorService.scoped(to: alice.userId).setUserAgentCredential(input())) { error in
      guard case NoteServiceError.accountUnavailable = error else {
        return XCTFail("expected accountUnavailable, got \(error)")
      }
    }
  }

  func testSchemaCreatesCredentialTableIdempotently() throws {
    let driver = try makeNoteDriver()
    try NoteStoreSchema.prepare(on: driver)
    try NoteStoreSchema.prepare(on: driver)
    try driver.withDatabase { database in
      XCTAssertTrue(try database.tableExists("user_agent_credentials"))
    }
  }

  func testConfigurationDefaultsAndBounds() throws {
    let absent: KaibaAIConfiguration? = nil
    XCTAssertTrue(absent.resolvedUserAgent.isEnabled)
    XCTAssertFalse(absent.resolvedUserAgent.customBaseURLAllowed)
    XCTAssertEqual(absent.resolvedUserAgent.resolvedMaxToolRounds, KaibaUserAgentConfiguration.defaultMaxToolRounds)

    let decoded = try JSONDecoder().decode(
      KaibaConfiguration.self,
      from: Data(#"{"ai":{"userAgent":{"enabled":false,"allowCustomBaseURL":true,"maxToolRounds":9999}}}"#.utf8)
    )
    let resolved = decoded.ai.resolvedUserAgent
    XCTAssertFalse(resolved.isEnabled)
    XCTAssertTrue(resolved.customBaseURLAllowed)
    XCTAssertEqual(resolved.resolvedMaxToolRounds, KaibaUserAgentConfiguration.maximumConfigurableToolRounds)
  }
}
