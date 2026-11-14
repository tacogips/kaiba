import Foundation
import XCTest
@testable import AppCore

final class CurrentAgentModelsTests: XCTestCase {
  func testCurrentVendorModelsReplaceLegacyDefaultWithoutChangingCustomModelIDs() {
    XCTAssertEqual(CurrentAgentModels.resolved("gpt-5.6-luna", vendor: "codex"), "gpt-6.1-sol")
    XCTAssertEqual(CurrentAgentModels.resolved("claude-opus-5", vendor: "anthropic"), "claude-opus-5-5")
    XCTAssertEqual(CurrentAgentModels.resolved("gemini-2.5-flash", vendor: "gemini"), "gemini-4-argon")
    XCTAssertEqual(CurrentAgentModels.resolved("private-model", vendor: "openai"), "private-model")
    XCTAssertFalse(CurrentAgentModels.models(for: "openai").contains("gpt-5.6-luna"))
  }

  func testCrossVendorServerRoutingRequiresOptInAndClearsOtherVendorsCredentialOverride() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: directory.path))
    let gateway = AgentGatewayCLIInvoker(vendor: "codex", model: "gpt-6.1-sol", apiKeyEnvironment: "CODEX_ONLY_KEY")
    let disabled = KaibaAutoActionDispatcher(service: service, invoker: gateway)
    XCTAssertThrowsError(try disabled.resolveChatRuntime(for: service, selectedProvider: "server:gemini"))
    let enabled = KaibaAutoActionDispatcher(service: service, invoker: gateway, allowedChatProviders: ["gemini", "claude-code"])
    let selection = try enabled.resolveChatRuntime(for: service, selectedProvider: "server:gemini")
    let selectedGateway = try XCTUnwrap(selection.invoker as? AgentGatewayCLIInvoker)
    XCTAssertEqual(selectedGateway.vendor, "gemini")
    XCTAssertNil(selectedGateway.apiKeyEnvironment)
    XCTAssertEqual(selection.providerOverride, "gemini")
    XCTAssertFalse(selection.usesPersonalRuntime)
    XCTAssertThrowsError(try enabled.resolveChatRuntime(for: service, selectedProvider: "server:openai"))
    let noSubscription = KaibaAutoActionDispatcher(service: service, invoker: gateway, allowedChatProviders: ["codex"])
    XCTAssertThrowsError(try noSubscription.resolveChatRuntime(for: service, selectedProvider: "server:codex"))
  }
}
