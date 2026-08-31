import Foundation
@testable import AppCore
import XCTest

final class AgentGatewayServedSafetyTests: NoteTestCase {
  func testServedFactoryAndReconciliationRejectReservedCredentialEnvironmentNames() throws {
    for environmentName in ["HOME", "PATH", "PROVIDER-TOKEN"] {
      let configuration = servedConfiguration(apiKeyEnvironment: environmentName)
      XCTAssertNil(AgentInvokerFactory.makeInvoker(
        configuration: configuration,
        environment: [environmentName: "selected-provider-secret"],
        executionMode: .served
      ))
      XCTAssertTrue(AgentInvokerFactory.describeAvailability(
        configuration: configuration,
        environment: [environmentName: "selected-provider-secret"],
        executionMode: .served
      ).contains("non-reserved, valid"))
    }

    let service = try makeService()
    let configuration = servedConfiguration(apiKeyEnvironment: "HOME")
    let environment = ["HOME": "selected-provider-secret"]
    let lines = try AIAutoActionReconciliation.reconcile(
      service: service,
      aiConfiguration: configuration,
      invokerAvailable: AgentInvokerFactory.makeInvoker(
        configuration: configuration,
        environment: environment,
        executionMode: .served
      ) != nil,
      environment: environment,
      executionMode: .served
    )

    XCTAssertFalse(try service.listAutoActions().contains(where: \.enabled))
    XCTAssertTrue(lines.contains(where: { $0.contains("non-reserved, valid") }))
  }

  func testServedReservedCredentialNamesFailBeforeEnvironmentConstruction() async throws {
    for environmentName in ["HOME", "PATH"] {
      let invoker = AgentGatewayCLIInvoker(
        commandPath: "/bin/echo",
        vendor: "openrouter",
        model: "test-model",
        apiKeyEnvironment: environmentName,
        environment: [environmentName: "selected-provider-secret"],
        executionMode: .served
      )
      do {
        _ = try await invoker.invoke(AgentInvocationRequest(
          purpose: .chat,
          systemPrompt: "system",
          turns: [AgentInvocationTurn(role: .user, markdown: "hello")]
        ))
        XCTFail("expected reserved served environment name \(environmentName) to be rejected")
      } catch AgentInvocationError.unavailable(let message) {
        XCTAssertEqual(message, "server agent-gateway is unavailable")
      }
    }
  }

  #if os(macOS)
  func testServedMissingBinaryNeverPersistsConfiguredPathInChatOrTranslation() async throws {
    let binary = try makeExecutableGatewayScript("#!/bin/sh\nexit 0\n")
    let credential = "selected-provider-secret"
    let invoker = AgentGatewayCLIInvoker(
      commandPath: binary.path,
      vendor: "openrouter",
      model: "test-model",
      apiKeyEnvironment: "PROVIDER_TOKEN",
      environment: ["PROVIDER_TOKEN": credential],
      executionMode: .served
    )
    try invoker.validateAvailability()
    try FileManager.default.removeItem(at: binary)

    let service = try makeService()
    let subject = try service.createNote(bodyMarkdown: "# Subject\nBody")
    let conversation = try service.startAgentConversation(subjectNoteId: subject.noteId)
    let turn = try service.appendPendingAgentChatTurn(
      conversationNotebookId: conversation.notebookId,
      userMarkdown: "Question",
      agentAvailable: true
    )
    do {
      try await service.generateAgentChatReply(turnNoteId: turn.noteId, invoker: invoker)
      XCTFail("expected removed gateway binary to fail")
    } catch AgentInvocationError.unavailable(let message) {
      XCTAssertEqual(message, "server agent-gateway is unavailable")
    }
    let chatError = try XCTUnwrap(NoteService.chatTurnState(of: service.getNote(turn.noteId))?.errorMessage)
    XCTAssertTrue(chatError.contains("server agent-gateway is unavailable"))
    XCTAssertFalse(chatError.contains(binary.path))
    XCTAssertFalse(chatError.contains(credential))

    let source = try service.createNotebookWithNotes(
      title: "Source",
      pages: [NotePageDraft(bodyMarkdown: "# Source\nBody")]
    )
    let translation = try service.startNotebookTranslation(
      sourceNotebookId: source.notebook.notebookId,
      targetLanguage: "English"
    )
    do {
      _ = try await AITranslationService(service: service, invoker: invoker).run(
        translationNotebookId: translation.notebookId
      )
      XCTFail("expected removed gateway binary to fail")
    } catch AgentInvocationError.unavailable(let message) {
      XCTAssertEqual(message, "server agent-gateway is unavailable")
    }
    let translationError = try XCTUnwrap(
      NoteService.translationState(of: service.getNotebook(translation.notebookId))?.errorMessage
    )
    XCTAssertTrue(translationError.contains("server agent-gateway is unavailable"))
    XCTAssertFalse(translationError.contains(binary.path))
    XCTAssertFalse(translationError.contains(credential))
  }
  #endif

  private func servedConfiguration(apiKeyEnvironment: String) -> KaibaAIConfiguration {
    KaibaAIConfiguration(
      agent: KaibaAgentBackendConfiguration(
        backend: "agent-gateway-cli",
        commandPath: "/bin/echo",
        provider: "openrouter",
        model: "test-model",
        apiKeyEnvironmentVariable: apiKeyEnvironment
      ),
      autoTag: KaibaAutoTagConfiguration(auto: .on)
    )
  }

  private func makeExecutableGatewayScript(_ script: String) throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/AppCoreTests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("served-gateway-\(UUID().uuidString).sh")
    try Data(script.utf8).write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
  }
}
