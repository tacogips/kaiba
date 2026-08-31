import Foundation

/// Serializes callback-driven provider chunks without retaining the complete
/// reply in AppCore. The callback remains synchronous for ACP pipe readers;
/// returning false tells a cooperative producer to stop once its bounded
/// output budget is exhausted.
final class AgentReplyChunkRelay: @unchecked Sendable {
  private let lock = NSLock()
  private let publish: @Sendable (String) async -> Void
  private var retainedBytes = 0
  private var retainedChunks = 0
  private var overflowed = false
  private var tail: Task<Void, Never>?

  init(publish: @escaping @Sendable (String) async -> Void) {
    self.publish = publish
  }

  /// Returns false after the hard output budget is reached. No rejected chunk
  /// is retained or scheduled, so an uncooperative source remains bounded.
  func append(_ chunk: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !overflowed,
          AgentReplyOutputLimits.accepts(
            chunk,
            retainedBytes: retainedBytes,
            retainedChunks: retainedChunks
          )
    else {
      overflowed = true
      return false
    }
    retainedBytes += chunk.utf8.count
    retainedChunks += 1
    let previous = tail
    let publish = publish
    tail = Task {
      if let previous {
        await previous.value
      }
      await publish(chunk)
    }
    return true
  }

  /// Drains ordered publications before a terminal state is admitted. This
  /// deliberately retains only task metadata, bounded by `maximumChunks`.
  func finishPublishing() async throws {
    let (pending, didOverflow) = lock.withLock { (tail, overflowed) }
    if let pending {
      await pending.value
    }
    guard !didOverflow else {
      throw AgentInvocationError.failed("agent reply exceeds the 256 KiB or 256-chunk output limit")
    }
  }
}
