import Foundation

import AppCore
import XCTest
@testable import AppGraphQL

/// `design-docs/specs/user-agent-tools.md`, UA5/UA7: the credential surface
/// over GraphQL, the write-only key, and `agentModels` reflecting the user.
final class UserAgentCredentialGraphQLTests: XCTestCase {
  func testSetQueryToggleAndClearNeverEchoTheKey() async throws {
    let base = try makeNoteService()
    let alice = try base.createUser(email: "alice@example.com", displayName: "Alice")
    let service = GraphQLNoteGraphQLService(service: base.scoped(to: alice.userId))
    let executor = NoteGraphQLDocumentExecutor(service: service)

    let set = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation Set($input: SetUserAgentCredentialInput!) {
        setUserAgentCredential(input: $input) {
          result { accepted status diagnostics }
          featureEnabled
          customBaseURLAllowed
          providers
          credential { provider keyHint baseURL defaultModel enabled updatedAt }
        }
      }
      """,
      variables: [
        "input": .object([
          "provider": .string("openrouter"),
          "apiKey": .string("sk-or-v1-supersecret-4242"),
          "defaultModel": .string("openai/gpt-5")
        ])
      ],
      operationName: "Set"
    ))
    XCTAssertTrue(set.handled)
    let setPayload = try payload(set.body, field: "setUserAgentCredential")
    XCTAssertEqual(setPayload["result"]?["accepted"]?.asBool, true)
    XCTAssertEqual(setPayload["featureEnabled"]?.asBool, true)
    XCTAssertEqual(setPayload["providers"]?.asArray?.count, UserAgentProvider.allCases.count)
    XCTAssertEqual(setPayload["credential"]?["keyHint"]?.asString, "4242")
    XCTAssertEqual(setPayload["credential"]?["provider"]?.asString, "openrouter")
    let rendered = try JSONValue.object(set.body).encodedString()
    XCTAssertFalse(rendered.contains("supersecret"))

    let query = await executor.execute(GraphQLDocumentRequest(
      query: "query Q { userAgentCredential { result { accepted status } credential { defaultModel enabled } } }",
      variables: [:],
      operationName: "Q"
    ))
    let queried = try payload(query.body, field: "userAgentCredential")
    XCTAssertEqual(queried["credential"]?["defaultModel"]?.asString, "openai/gpt-5")
    XCTAssertEqual(queried["credential"]?["enabled"]?.asBool, true)

    let models = await service.agentModels()
    XCTAssertTrue(models.result.accepted)
    XCTAssertEqual(models.result.status, "ok")
    XCTAssertEqual(models.configuredModel, "openai/gpt-5")
    XCTAssertEqual(models.models.map(\.modelId), ["openai/gpt-5"])
    XCTAssertFalse(models.discoveryAvailable)

    let toggled = await executor.execute(GraphQLDocumentRequest(
      query: "mutation T { setUserAgentCredentialEnabled(enabled: false) { result { accepted } credential { enabled } } }",
      variables: [:],
      operationName: "T"
    ))
    XCTAssertEqual(try payload(toggled.body, field: "setUserAgentCredentialEnabled")["credential"]?["enabled"]?.asBool, false)
    // A disabled credential no longer drives agentModels.
    let afterDisable = await service.agentModels()
    XCTAssertEqual(afterDisable.result.status, "agent-unavailable")

    let cleared = await executor.execute(GraphQLDocumentRequest(
      query: "mutation C { clearUserAgentCredential { result { accepted status } credential { keyHint } } }",
      variables: [:],
      operationName: "C"
    ))
    let clearedPayload = try payload(cleared.body, field: "clearUserAgentCredential")
    XCTAssertEqual(clearedPayload["result"]?["accepted"]?.asBool, true)
    XCTAssertEqual(clearedPayload["credential"], .null)
  }

  func testValidationAndPolicyErrorsAreReportedNotThrown() async throws {
    let base = try makeNoteService()
    let alice = try base.createUser(email: "alice@example.com", displayName: "Alice")
    let service = GraphQLNoteGraphQLService(service: base.scoped(to: alice.userId))

    let unknownProvider = await service.setUserAgentCredential(GraphQLSetUserAgentCredentialInput(
      provider: "gemini", apiKey: "k", defaultModel: "m"
    ))
    XCTAssertFalse(unknownProvider.result.accepted)
    XCTAssertEqual(unknownProvider.result.status, "invalid_request")

    let customURL = await service.setUserAgentCredential(GraphQLSetUserAgentCredentialInput(
      provider: "openai", apiKey: "sk-1", defaultModel: "gpt-5", baseURL: "https://proxy.example.com/v1"
    ))
    XCTAssertFalse(customURL.result.accepted)
    XCTAssertEqual(customURL.result.status, "invalid_request")

    let missing = await service.setUserAgentCredentialEnabled(true)
    XCTAssertFalse(missing.result.accepted)
    XCTAssertEqual(missing.result.status, "not_found")

    let permissive = GraphQLNoteGraphQLService(
      service: base.scoped(to: alice.userId),
      userAgentConfiguration: KaibaUserAgentConfiguration(allowCustomBaseURL: true)
    )
    let accepted = await permissive.setUserAgentCredential(GraphQLSetUserAgentCredentialInput(
      provider: "openai-compatible", apiKey: "sk-1", defaultModel: "local", baseURL: "http://localhost:11434/v1"
    ))
    XCTAssertTrue(accepted.result.accepted)
    XCTAssertEqual(accepted.credential?.baseURL, "http://localhost:11434/v1")
    XCTAssertTrue(accepted.customBaseURLAllowed)
  }

  func testFeatureDisabledAndUnauthenticatedPrincipals() async throws {
    let base = try makeNoteService()
    let alice = try base.createUser(email: "alice@example.com", displayName: "Alice")
    let disabled = GraphQLNoteGraphQLService(
      service: base.scoped(to: alice.userId),
      agentModel: "server-model",
      userAgentConfiguration: KaibaUserAgentConfiguration(enabled: false)
    )
    let hidden = await disabled.userAgentCredential()
    XCTAssertEqual(hidden.result.status, "feature-disabled")
    XCTAssertFalse(hidden.featureEnabled)
    let rejected = await disabled.setUserAgentCredential(GraphQLSetUserAgentCredentialInput(
      provider: "anthropic", apiKey: "sk", defaultModel: "m"
    ))
    XCTAssertFalse(rejected.result.accepted)
    let serverModels = await disabled.agentModels()
    XCTAssertEqual(serverModels.configuredModel, "server-model")

    let anonymous = GraphQLNoteGraphQLService(
      service: base.scoped(to: NoteStoreSchema.defaultUserId).unauthenticated()
    )
    let denied = await anonymous.setUserAgentCredential(GraphQLSetUserAgentCredentialInput(
      provider: "anthropic", apiKey: "sk-anon", defaultModel: "m"
    ))
    XCTAssertFalse(denied.result.accepted)
    XCTAssertEqual(denied.result.status, "not_found")
    let anonymousQuery = await anonymous.userAgentCredential()
    XCTAssertEqual(anonymousQuery.result.status, "not_found")
  }

  func testTurnIsUnavailableWithoutAnyRuntimeAndPendingWithACredential() async throws {
    let base = try makeNoteService()
    let alice = try base.createUser(email: "alice@example.com", displayName: "Alice")
    // A server without ai.agent still installs a dispatcher for personal agents.
    let dispatcher = KaibaAutoActionDispatcher(
      service: base,
      invoker: nil,
      userAgentRuntime: UserAgentRuntimeFactory(configuration: KaibaUserAgentConfiguration())
    )
    var withDispatcher = base.scoped(to: alice.userId)
    withDispatcher.autoActionDispatcher = dispatcher
    let service = GraphQLNoteGraphQLService(service: withDispatcher)
    let subject = try withDispatcher.createNote(bodyMarkdown: "# Subject\nBody.")

    let unavailable = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Anyone there?"
    ))
    XCTAssertTrue(unavailable.result.accepted)
    XCTAssertEqual(unavailable.agentStatus, "agent-unavailable")

    _ = try withDispatcher.setUserAgentCredential(UserAgentCredentialInput(
      provider: .anthropic, apiKey: "sk-ant-1", defaultModel: "claude-opus-5"
    ))
    let pending = await service.sendAgentChatMessage(GraphQLSendAgentChatMessageInput(
      subjectNoteId: subject.noteId, userMarkdown: "Now?", model: "claude-opus-5"
    ))
    XCTAssertTrue(pending.result.accepted, "\(pending.result)")
    XCTAssertEqual(pending.agentStatus, "pending")
    await withDispatcher.drainAutoActionDispatches()
  }

  func testSchemaContractExposesTheSurface() {
    let schema = GraphQLContractProjector.schemaContract
    XCTAssertTrue(schema.contains("userAgentCredential: UserAgentCredentialPayload!"))
    XCTAssertTrue(schema.contains("setUserAgentCredential(input: SetUserAgentCredentialInput!): UserAgentCredentialPayload!"))
    XCTAssertTrue(schema.contains("setUserAgentCredentialEnabled(enabled: Boolean!): UserAgentCredentialPayload!"))
    XCTAssertTrue(schema.contains("clearUserAgentCredential: UserAgentCredentialPayload!"))
    XCTAssertTrue(schema.contains("type UserAgentCredentialSummary"))
    XCTAssertFalse(schema.contains("apiKey: String!, defaultModel: String!, baseURL: String, enabled: Boolean }\ntype"))
  }

  // MARK: - Helpers

  private func makeNoteService(function: String = #function) throws -> NoteService {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  }

  private func payload(_ body: JSONObject, field: String) throws -> JSONObject {
    guard case let .object(data)? = body["data"], case let .object(payload)? = data[field] else {
      throw NSError(domain: "UserAgentCredentialGraphQLTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "expected object at data.\(field): \(body)"
      ])
    }
    return payload
  }
}
