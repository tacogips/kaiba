import Foundation
@testable import AppCore
import XCTest

final class NotebookIngestPublicAPITests: XCTestCase {
  func testDeferredFinalizationPublishesAndEnqueuesExactlyOnce() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("app-core-deferred-finalization-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let observer = NotebookIngestRecordingChangeObserver()
    let service = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: root.path),
      changeObserver: observer
    )
    _ = try service.configureAutoAction(
      actionId: AutoActionID("deferred-notebook-created"),
      trigger: .notebookCreated,
      workflowId: WorkflowID("deferred-notebook-workflow")
    )
    _ = try service.configureAutoAction(
      actionId: AutoActionID("deferred-note-created"),
      trigger: .noteCreated,
      workflowId: WorkflowID("deferred-note-workflow")
    )
    let deferred = try service.createNotebookWithNotes(
      title: "Deferred lifecycle",
      metaJSON: #"{"caller":"preserved"}"#,
      pages: [NotePageDraft(bodyMarkdown: "# Deferred page")],
      autoActionPolicy: .deferredUntilFinalized
    )
    let notebookId = deferred.notebook.notebookId

    XCTAssertTrue(try dispatches(for: notebookId, in: service).isEmpty)
    XCTAssertTrue(events(for: notebookId, in: observer).isEmpty)
    XCTAssertTrue(try ingestActions(for: notebookId, in: service).isEmpty)

    try service.finalizeDeferredNotebookIngestAutoActions(deferred)
    let finalizedDispatches = try dispatches(for: notebookId, in: service)
    XCTAssertEqual(
      Set(finalizedDispatches.map(\.record.action.actionId)),
      [
        AutoActionID("deferred-note-created"),
        AutoActionID("deferred-notebook-created")
      ]
    )
    XCTAssertEqual(events(for: notebookId, in: observer).map(\.kind), [NoteChangeEventKind.notebookCreated])
    XCTAssertEqual(try ingestActions(for: notebookId, in: service).count, 1)
    XCTAssertEqual(try service.getNotebook(notebookId).metaJSON, #"{"caller":"preserved"}"#)

    XCTAssertThrowsError(try service.finalizeDeferredNotebookIngestAutoActions(deferred)) { error in
      XCTAssertEqual(
        error as? NoteServiceError,
        .conflict("notebook ingest auto-actions are not pending finalization")
      )
    }
    XCTAssertEqual(try dispatches(for: notebookId, in: service), finalizedDispatches)
    XCTAssertEqual(events(for: notebookId, in: observer).count, 1)
    XCTAssertEqual(try ingestActions(for: notebookId, in: service).count, 1)

    let immediate = try service.createNotebookWithNotes(
      title: "Immediate lifecycle",
      pages: [NotePageDraft(bodyMarkdown: "# Immediate page")]
    )
    let immediateId = immediate.notebook.notebookId
    let immediateDispatches = try dispatches(for: immediateId, in: service)
    let immediateEvents = events(for: immediateId, in: observer)
    XCTAssertThrowsError(try service.finalizeDeferredNotebookIngestAutoActions(immediate))
    XCTAssertEqual(try dispatches(for: immediateId, in: service), immediateDispatches)
    XCTAssertEqual(events(for: immediateId, in: observer), immediateEvents)
  }

  func testPendingIngestCreatedTagsStayOutOfPublicCatalogUntilReveal() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("app-core-pending-tags-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      .scoped(to: NoteStoreSchema.defaultUserId)
    let preexisting = try service.defineTag(name: "preexisting-unused")
    let shared = try service.defineTag(name: "preexisting-shared")
    let claim = try service.claimNotebookIngestRequest(
      idempotencyKey: "app-core-pending-tags",
      canonicalRequest: Data("app-core-pending-tags".utf8)
    )
    guard case let .execute(identity) = claim else {
      return XCTFail("expected a new ingest claim")
    }
    let ingest = try service.createClaimedNotebookIngest(
      identity,
      title: "Pending tag catalog",
      kindTagName: "pending-kind",
      callerMetadataJSON: nil,
      pages: [NotePageDraft(
        bodyMarkdown: "# Pending tag page",
        tags: [NoteTagInput(name: shared.name), NoteTagInput(name: "pending-topic")]
      )],
      originatingActionId: nil
    )

    let publicPendingNames = Set(try service.listTags().map(\.name))
    XCTAssertTrue(publicPendingNames.contains(preexisting.name))
    XCTAssertTrue(publicPendingNames.contains(shared.name))
    XCTAssertFalse(publicPendingNames.contains("pending-kind"))
    XCTAssertFalse(publicPendingNames.contains("pending-topic"))
    let internalPendingNames = Set(try service.pendingNotebookIngestScope().listTags().map(\.name))
    XCTAssertTrue(internalPendingNames.contains("pending-kind"))
    XCTAssertTrue(internalPendingNames.contains("pending-topic"))

    try service.completeNotebookIngestRequest(
      identity,
      ingest: ingest,
      resultJSON: "{}",
      enqueueAutoActions: false
    )
    let visibleNames = Set(try service.listTags().map(\.name))
    XCTAssertTrue(visibleNames.contains(preexisting.name))
    XCTAssertTrue(visibleNames.contains(shared.name))
    XCTAssertTrue(visibleNames.contains("pending-kind"))
    XCTAssertTrue(visibleNames.contains("pending-topic"))
  }

  func testPendingIngestCapabilityIsAbsentFromPublicAppCoreSymbols() throws {
    let targetInfo = try JSONDecoder().decode(
      AppCoreSwiftTargetInfo.self,
      from: try runAppCoreXcrun(["swift", "-print-target-info"])
    )
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let modules = repositoryRoot
      .appendingPathComponent(".build")
      .appendingPathComponent(targetInfo.target.unversionedTriple)
      .appendingPathComponent("debug/Modules")
    let anydocHeaders = repositoryRoot
      .appendingPathComponent(".build/artifacts/anydoc-swift/CAnydocFFI")
      .appendingPathComponent("AnydocFFI.xcframework/macos-arm64_x86_64/Headers")
    let sdkPathData = try runAppCoreXcrun(["--sdk", "macosx", "--show-sdk-path"])
    guard let sdkPath = String(bytes: sdkPathData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw AppCorePublicAPITestError.invalidUTF8(tool: "xcrun")
    }
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("app-core-public-api-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: output) }

    let extractorArguments = [
      "swift-symbolgraph-extract",
      "-module-name", "AppCore",
      "-I", modules.path,
      "-sdk", sdkPath,
      "-Xcc", "-fmodule-map-file=\(anydocHeaders.appendingPathComponent("module.modulemap").path)",
      "-Xcc", "-I",
      "-Xcc", anydocHeaders.path,
      "-output-dir", output.path,
      "-target", targetInfo.target.triple,
      "-minimum-access-level", "public",
      "-skip-synthesized-members"
    ]
    do {
      _ = try runAppCoreXcrun(extractorArguments)
    } catch {
      // mise and Xcode can provide different builds of the same Swift version.
      // Use the extractor beside SwiftPM's active toolchain when Xcode cannot
      // load the module produced in the shared build directory.
      _ = try runAppCoreEnvironmentTool(extractorArguments)
    }
    let graph = try JSONDecoder().decode(
      AppCoreSymbolGraph.self,
      from: Data(contentsOf: output.appendingPathComponent("AppCore.symbols.json"))
    )
    let exposedComponents = Set(graph.symbols.flatMap(\.pathComponents))
    XCTAssertTrue(exposedComponents.contains("NoteService"))
    let forbiddenComponents = [
      "NotebookIngestRequestIdentity",
      "NotebookIngestRequestRecovery",
      "NotebookIngestRequestClaim",
      "NotebookIngestAutoActionPolicy",
      "claimNotebookIngestRequest(idempotencyKey:canonicalRequest:)",
      "pendingNotebookIngestScope()",
      "pendingNotebookIngestMetadata(callerMetadataJSON:identity:)",
      "pendingNotebookIngestCreatedTagIds(_:)",
      "completeNotebookIngestRequest(_:ingest:resultJSON:enqueueAutoActions:originatingActionId:)",
      "recordNotebookIngestRecovery(_:ingest:resultJSON:enqueueAutoActions:originatingActionId:)",
      "abandonNotebookIngestRequest(_:)",
      "completedNotebookIngestResult(_:)",
      "recoverableNotebookIngestRequest(_:)",
      "isPendingNotebookIngestMetadata(_:)",
      "finalizeDeferredNotebookIngestAutoActions(_:originatingActionId:)",
      "createNotebookWithNotes(title:kindTagName:metaJSON:pages:notebookReadOnly:provenance:assignedBy:originatingActionId:autoActionPolicy:)"
    ]
    for component in forbiddenComponents {
      XCTAssertFalse(exposedComponents.contains(component), "unexpected public AppCore symbol: \(component)")
    }
  }

  private func dispatches(
    for notebookId: NotebookID,
    in service: NoteService
  ) throws -> [AutoActionDispatchAttempt] {
    try service.listAutoActionDispatchAttempts().filter { $0.record.event.notebookId == notebookId }
  }

  private func events(
    for notebookId: NotebookID,
    in observer: NotebookIngestRecordingChangeObserver
  ) -> [NoteChangeEvent] {
    observer.events.filter { $0.notebookId == notebookId }
  }

  private func ingestActions(
    for notebookId: NotebookID,
    in service: NoteService
  ) throws -> [NoteActionLogEntry] {
    try service.actionHistory(limit: 500).filter {
      $0.notebookId == notebookId && $0.kind == .notebookIngested
    }
  }

  private func runAppCoreXcrun(_ arguments: [String]) throws -> Data {
    try runAppCoreTool(executable: "/usr/bin/xcrun", arguments: arguments, tool: "xcrun")
  }

  private func runAppCoreEnvironmentTool(_ arguments: [String]) throws -> Data {
    try runAppCoreTool(
      executable: "/usr/bin/env",
      arguments: arguments,
      tool: arguments.first ?? "tool"
    )
  }

  private func runAppCoreTool(
    executable: String,
    arguments: [String],
    tool: String
  ) throws -> Data {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let stderr = errors.fileHandleForReading.readDataToEndOfFile()
      throw AppCorePublicAPITestError.commandFailed(
        tool: tool,
        status: process.terminationStatus,
        diagnostic: String(bytes: stderr, encoding: .utf8) ?? "<non-UTF-8 diagnostics>"
      )
    }
    return stdout
  }
}

private final class NotebookIngestRecordingChangeObserver: NoteChangeObserving, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [NoteChangeEvent] = []

  func noteStoreDidChange(_ event: NoteChangeEvent) {
    lock.withLock { recorded.append(event) }
  }

  var events: [NoteChangeEvent] {
    lock.withLock { recorded }
  }
}

private struct AppCoreSwiftTargetInfo: Decodable {
  struct Target: Decodable {
    let triple: String
    let unversionedTriple: String
  }

  let target: Target
}

private struct AppCoreSymbolGraph: Decodable {
  struct Symbol: Decodable {
    let pathComponents: [String]
  }

  let symbols: [Symbol]
}

private enum AppCorePublicAPITestError: Error {
  case commandFailed(tool: String, status: Int32, diagnostic: String)
  case invalidUTF8(tool: String)
}
