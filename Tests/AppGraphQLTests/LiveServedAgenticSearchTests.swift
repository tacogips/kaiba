import AppCore
import AppGraphQL
import Foundation
import XCTest

final class LiveServedAgenticSearchTests: XCTestCase {
  func testServedAgenticSearchReturnsAnswer() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["KAIBA_LIVE_AGENT_GATEWAY"] == "1",
      let apiKey = environment["OPENROUTER_API_KEY"], !apiKey.isEmpty
    else {
      throw XCTSkip("Set KAIBA_LIVE_AGENT_GATEWAY=1 and OPENROUTER_API_KEY to run the served agenticSearch live test")
    }

    let model = environment["KAIBA_LIVE_AGENT_GATEWAY_MODEL"] ?? "openai/gpt-5-mini"
    let configuration = KaibaAIConfiguration(agent: KaibaAgentBackendConfiguration(
      backend: KaibaAgentBackendConfiguration.agentGatewayCLIBackend,
      commandPath: nil,
      provider: "openrouter",
      model: model,
      apiKeyEnvironmentVariable: "OPENROUTER_API_KEY"
    ))
    let availability = AgentInvokerFactory.describeAvailability(
      configuration: configuration,
      environment: environment,
      executionMode: .served
    )
    guard let invoker = AgentInvokerFactory.makeInvoker(
      configuration: configuration,
      environment: environment,
      executionMode: .served
    ) else {
      XCTFail("agent-gateway served runtime unavailable: \(availability)")
      return
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppGraphQLTests", isDirectory: true)
      .appendingPathComponent("LiveServedAgenticSearch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let noteService = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    _ = try noteService.createNote(bodyMarkdown: "Yamada Taro leads the lighthouse survey project.")
    _ = try noteService.createNote(bodyMarkdown: "The lighthouse survey tracks coastal beacons.")

    let service = GraphQLNoteGraphQLService(
      service: noteService,
      agentInvoker: invoker,
      agentProvider: "openrouter",
      agentModel: model
    )
    let executor = NoteGraphQLDocumentExecutor(service: service)
    let response = await executor.execute(GraphQLDocumentRequest(query: """
      query {
        agenticSearch(query: "Who leads the lighthouse survey?", limit: 5) {
          status answerMarkdown result { accepted status diagnostics }
        }
      }
      """))

    let payload = response.body["data"]?.asObject?["agenticSearch"]?.asObject
    let status = payload?["status"]?.asString
    let answer = payload?["answerMarkdown"]?.asString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let diagnostics = payload?["result"]?.asObject?["diagnostics"]?.asArray?
      .compactMap(\.asString).joined(separator: "; ") ?? "unavailable"
    XCTAssertEqual(status, "ok", "Sanitized agenticSearch diagnostics: \(diagnostics)")
    XCTAssertFalse(answer.isEmpty, "Sanitized agenticSearch diagnostics: \(diagnostics)")
  }
}
