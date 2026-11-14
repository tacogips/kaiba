import Foundation

/// Identifies the outbox attempt that owns a leased chat stream.  A recovered
/// attempt supersedes the previous lease, so stream publishers must admit
/// chunks and terminal states only from the currently registered lease.
public struct AgentReplyStreamLease: Equatable, Sendable {
  public let dispatchId: AutoActionDispatchID
  public let token: String
  /// `attemptNumber` is monotonic for one dispatch and prevents a delayed
  /// older worker from re-registering after recovery already admitted a newer
  /// lease to the stream hub.
  public let attemptNumber: Int

  public init(dispatchId: AutoActionDispatchID, token: String, attemptNumber: Int) {
    self.dispatchId = dispatchId
    self.token = token
    self.attemptNumber = attemptNumber
  }
}

/// End-to-end limits for agent reply data retained or relayed by this
/// process. Keeping the producer-side limits aligned with the serving hub
/// prevents an unbounded provider from consuming memory before the hub can
/// apply its own retention policy.
public enum AgentReplyOutputLimits {
  public static let maximumBytes = 256 * 1024
  public static let maximumChunks = 256

  public static func accepts(_ text: String, retainedBytes: Int, retainedChunks: Int) -> Bool {
    let byteCount = text.utf8.count
    return retainedChunks < maximumChunks
      && byteCount <= maximumBytes
      && retainedBytes <= maximumBytes - byteCount
  }

  public static func validateFinalReply(_ text: String) throws {
    guard text.utf8.count <= maximumBytes else {
      throw AgentInvocationError.failed("agent reply exceeds the 256 KiB output limit")
    }
  }
}

/// Receives incremental agent output while a chat reply is being generated.
/// AppCore publishes through this seam; the serve layer's stream hub
/// implements it and fans chunks out to long-polling web clients, giving the
/// memo pane its streaming chat UX over the single-write HTTP server.
public protocol AgentReplyStreamPublishing: Sendable {
  /// `libraryId` is captured with the provider context. The serving layer
  /// keeps it with every chunk so a later notebook move cannot weaken the
  /// visibility of already-generated content.
  func publishAgentReplyChunk(turnNoteId: NoteID, text: String, libraryId: LibraryID)
  /// `libraryId` is captured with the provider context even when the provider
  /// fails before emitting a chunk, so terminal metadata cannot weaken the
  /// visibility boundary.
  func finishAgentReplyStream(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID
  )

  /// Registers the lease that currently owns a turn's shared stream.  This
  /// admission is asynchronous so an actor-backed publisher can linearize a
  /// recovery handoff before either worker publishes output.
  func beginLeasedAgentReplyStream(
    turnNoteId: NoteID,
    lease: AgentReplyStreamLease
  ) async

  /// Publishes only when `lease` is still the stream's registered owner.
  func publishLeasedAgentReplyChunk(
    turnNoteId: NoteID,
    text: String,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) async

  /// Finishes only when `lease` is still the stream's registered owner.
  func finishLeasedAgentReplyStream(
    turnNoteId: NoteID,
    status: String,
    message: String?,
    libraryId: LibraryID,
    lease: AgentReplyStreamLease
  ) async
}

public extension AgentReplyStreamPublishing {
  func beginLeasedAgentReplyStream(turnNoteId _: NoteID, lease _: AgentReplyStreamLease) async {}

  func publishLeasedAgentReplyChunk(
    turnNoteId _: NoteID,
    text _: String,
    libraryId _: LibraryID,
    lease _: AgentReplyStreamLease
  ) async {}

  func finishLeasedAgentReplyStream(
    turnNoteId _: NoteID,
    status _: String,
    message _: String?,
    libraryId _: LibraryID,
    lease _: AgentReplyStreamLease
  ) async {}
}

/// An invoker that can surface the reply incrementally as the agent produces
/// it. `AgentGatewayCLIInvoker` conforms by parsing the ACP JSONL stream's
/// `agent_message_chunk` updates as they arrive on stdout.
public protocol AgentStreamingInvoking: AgentInvoking {
  func invoke(
    _ request: AgentInvocationRequest,
    onChunk: @escaping @Sendable (String) -> Bool
  ) async throws -> AgentInvocationResult
}
