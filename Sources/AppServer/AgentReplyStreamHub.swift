import Foundation
import AppCore

/// In-process fan-out behind `GET /note/agent-stream`. The auto-action
/// dispatcher publishes each ACP `agent_message_chunk` here while a chat
/// reply generates; web clients long-poll with a chunk cursor and render the
/// reply incrementally, which gives a streaming chat UX over the server's
/// single-write HTTP responses.
public actor AgentReplyStreamHub {
  /// Finished streams linger so a poller that raced the finish still reads the
  /// tail; the oldest are dropped past this cap.
  static let maximumStreams = 64

  public struct Poll: Equatable, Sendable {
    public var cursor: Int
    public var chunks: [String]
    public var done: Bool
    public var status: String?
    public var message: String?
  }

  private struct Stream {
    var chunks: [String] = []
    var done = false
    var status: String?
    var message: String?
    var sequence: UInt64
  }

  private var streams: [String: Stream] = [:]
  private var sequence: UInt64 = 0
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  public init() {}

  public func publish(turnNoteId: String, text: String) {
    var stream = streams[turnNoteId] ?? makeStream()
    stream.chunks.append(text)
    streams[turnNoteId] = stream
    wakeAll()
  }

  public func finish(turnNoteId: String, status: String, message: String?) {
    var stream = streams[turnNoteId] ?? makeStream()
    stream.done = true
    stream.status = status
    stream.message = message
    streams[turnNoteId] = stream
    wakeAll()
  }

  /// Suspends until the stream has chunks past `cursor` or finished, or until
  /// the timeout lapses. An unknown turn returns an empty pending poll so a
  /// client may subscribe before the dispatcher claims the turn.
  public func poll(
    turnNoteId: String,
    cursor: Int,
    timeoutNanoseconds: UInt64
  ) async -> Poll {
    if let ready = snapshot(turnNoteId: turnNoteId, cursor: cursor) {
      return ready
    }
    let id = UUID()
    let timeout = Task { [weak self] in
      try? await Task.sleep(nanoseconds: timeoutNanoseconds)
      await self?.wake(id)
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if Task.isCancelled {
          continuation.resume()
          return
        }
        waiters[id] = continuation
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
    timeout.cancel()
    return snapshot(turnNoteId: turnNoteId, cursor: cursor)
      ?? Poll(cursor: cursor, chunks: [], done: false, status: nil, message: nil)
  }

  private func makeStream() -> Stream {
    sequence += 1
    if streams.count >= Self.maximumStreams {
      let oldest = streams.min { $0.value.sequence < $1.value.sequence }
      if let oldest {
        streams.removeValue(forKey: oldest.key)
      }
    }
    return Stream(sequence: sequence)
  }

  /// Nil while there is nothing new past `cursor` and the stream is not done.
  private func snapshot(turnNoteId: String, cursor: Int) -> Poll? {
    guard let stream = streams[turnNoteId] else {
      return nil
    }
    let bounded = max(0, min(cursor, stream.chunks.count))
    guard stream.chunks.count > bounded || stream.done else {
      return nil
    }
    return Poll(
      cursor: stream.chunks.count,
      chunks: Array(stream.chunks[bounded...]),
      done: stream.done,
      status: stream.status,
      message: stream.message
    )
  }

  private func wake(_ id: UUID) {
    waiters.removeValue(forKey: id)?.resume()
  }

  private func wakeAll() {
    let resumed = waiters
    waiters.removeAll()
    for continuation in resumed.values {
      continuation.resume()
    }
  }
}

/// Bridges AppCore's synchronous publish callbacks onto the hub actor through
/// one ordered stream — chunks must land in emission order, and a detached
/// Task per chunk would not guarantee that.
public final class AgentReplyStreamHubPublisher: AgentReplyStreamPublishing, @unchecked Sendable {
  private enum Event {
    case chunk(turnNoteId: String, text: String)
    case finish(turnNoteId: String, status: String, message: String?)
  }

  private let continuation: AsyncStream<Event>.Continuation
  private let pump: Task<Void, Never>

  public init(hub: AgentReplyStreamHub) {
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    self.continuation = continuation
    pump = Task {
      for await event in stream {
        switch event {
        case let .chunk(turnNoteId, text):
          await hub.publish(turnNoteId: turnNoteId, text: text)
        case let .finish(turnNoteId, status, message):
          await hub.finish(turnNoteId: turnNoteId, status: status, message: message)
        }
      }
    }
  }

  deinit {
    continuation.finish()
    pump.cancel()
  }

  public func publishAgentReplyChunk(turnNoteId: String, text: String) {
    continuation.yield(.chunk(turnNoteId: turnNoteId, text: text))
  }

  public func finishAgentReplyStream(turnNoteId: String, status: String, message: String?) {
    continuation.yield(.finish(turnNoteId: turnNoteId, status: status, message: message))
  }
}
