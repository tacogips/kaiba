import Foundation
import XCTest
import AppCore
@testable import AppGraphQL

final class CrossVendorModelCatalogTests: XCTestCase {
  func testCatalogSeparatesOptedInServerRoutesAndRejectsDisabledVendors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let base = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: directory.path))
    let gateway = AgentGatewayCLIInvoker(vendor: "codex", model: "gpt-6.1-sol")
    let service = GraphQLNoteGraphQLService(service: base, agentInvoker: gateway, agentProvider: "codex", agentModel: "gpt-5.6-luna",
      agentAllowedProviders: ["codex", "claude-code", "gemini", "untrusted-vendor"])
    let claude = await service.agentModels(provider: "server:claude-code")
    XCTAssertTrue(claude.result.accepted)
    XCTAssertEqual(claude.configuredProvider, "server:claude-code")
    XCTAssertEqual(claude.configuredModel, "claude-opus-5-5")
    XCTAssertEqual(claude.models.map(\.modelId), CurrentAgentModels.models(for: "claude-code"))
    XCTAssertFalse(claude.providers.contains("server:untrusted-vendor"))
    let gemini = await service.agentModels(provider: "server:gemini")
    XCTAssertEqual(gemini.configuredModel, "gemini-4-argon")
    let defaultCatalog = await service.agentModels(provider: "server")
    XCTAssertEqual(defaultCatalog.configuredModel, "gpt-6.1-sol")
    let rejected = await service.sendAgentChatMessage(.init(userMarkdown: "Hello", model: "gpt-6.1-sol", provider: "server:openai"))
    XCTAssertFalse(rejected.result.accepted)
    let old = await service.sendAgentChatMessage(.init(userMarkdown: "Hello", model: "gpt-5.6-luna", provider: "server:codex"))
    XCTAssertFalse(old.result.accepted)
  }
}
