import Foundation
import XCTest
import AppCore
@testable import AppGraphQL

final class CodexSubscriptionGraphQLTests: XCTestCase {
  func testSubscriptionOptInAndProviderSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: directory.path))
    let user = try base.createUser(email: "subscription@example.com", displayName: "Subscriber")
    let scoped = base.scoped(to: user.userId)
    let disabled = GraphQLNoteGraphQLService(service: scoped)
    let input = GraphQLSetUserAgentCredentialInput(provider: "codex", apiKey: "", defaultModel: "test-model")
    let rejected = await disabled.setUserAgentCredential(input)
    XCTAssertFalse(rejected.result.accepted)
    let service = GraphQLNoteGraphQLService(
      service: scoped, userAgentConfiguration: .init(allowCodexSubscription: true)
    )
    let saved = await service.setUserAgentCredential(input)
    XCTAssertTrue(saved.result.accepted, String(describing: saved.result))
    XCTAssertEqual(saved.credential?.keyHint, "")
    let catalog = await service.agentModels()
    XCTAssertEqual(catalog.configuredProvider, "codex")
    XCTAssertEqual(catalog.providers, ["codex"])
    let document = await NoteGraphQLDocumentExecutor(service: service).execute(.init(
      query: "query Models($provider: String) { agentModels(provider: $provider) { providers configuredProvider configuredModel } }",
      variables: ["provider": .string("codex")], operationName: "Models"
    ))
    XCTAssertNil(document.body["errors"])
    XCTAssertEqual(document.body["data"]?["agentModels"]?["configuredProvider"], .string("codex"))
    let sent = await service.sendAgentChatMessage(.init(userMarkdown: "Hello", model: "test-model", provider: "codex"))
    XCTAssertTrue(sent.result.accepted, String(describing: sent.result))
    let turn = try scoped.getNote(XCTUnwrap(sent.turnNoteId))
    XCTAssertEqual(NoteService.chatTurnState(of: turn)?.provider, "codex")
    let unsupported = await service.sendAgentChatMessage(.init(userMarkdown: "Hello", provider: "cursor"))
    XCTAssertFalse(unsupported.result.accepted)
  }
}
