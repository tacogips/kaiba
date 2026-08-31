import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Serializes direct-child reaping and publishes its completion exactly once.
final class ProcessReapState: @unchecked Sendable {
  private let lock = NSLock()
  private let completion: ProcessCompletion
  private let leaderWaitpidReturnedObserver: (@Sendable () -> Void)?
  private let leaderReapedObserver: (@Sendable () -> Void)?
  private var reaped = false

  init(
    completion: ProcessCompletion,
    leaderWaitpidReturnedObserver: (@Sendable () -> Void)?,
    leaderReapedObserver: (@Sendable () -> Void)?
  ) {
    self.completion = completion
    self.leaderWaitpidReturnedObserver = leaderWaitpidReturnedObserver
    self.leaderReapedObserver = leaderReapedObserver
  }

  var isReaped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return reaped
  }

  /// Polls and publishes the direct child's exit. Returns true once another
  /// caller has reaped it or this call has published the completion.
  func pollForLeaderExit(processIdentifier: pid_t) -> Bool {
    let reapedStatus = inspectLeader(processIdentifier: processIdentifier)
    guard let reapedStatus else { return isReaped }
    publishReapedLeader(status: reapedStatus)
    return true
  }

  private func inspectLeader(processIdentifier: pid_t) -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    guard !reaped else { return nil }
    var status: Int32 = 0
    let waitedProcess = waitForLeader(processIdentifier: processIdentifier, status: &status)
    guard waitedProcess == processIdentifier || (waitedProcess == -1 && errno == ECHILD) else {
      return nil
    }
    leaderWaitpidReturnedObserver?()
    reaped = true
    return status
  }

  private func publishReapedLeader(status: Int32) {
    leaderReapedObserver?()
    completion.finish(status: gatewayProcessExitCode(from: status))
  }

  private func waitForLeader(processIdentifier: pid_t, status: inout Int32) -> pid_t {
    var waitedProcess: pid_t = -1
    repeat {
      waitedProcess = waitpid(processIdentifier, &status, WNOHANG)
    } while waitedProcess == -1 && errno == EINTR
    return waitedProcess
  }
}

/// Keeps a distinct, direct-child process as the process-group leader for one
/// invocation. Its unreaped PID is an ownership witness: a numeric group ID
/// cannot be reused while this child remains unreaped. Cleanup therefore never
/// uses the gateway leader's reusable PID after `waitpid` has consumed it.
enum ProcessGroupDescendantStatus: Sendable {
  case none
  case live
  case zombies
  case unavailable
}

private struct ProcessGroupMember {
  let processIdentifier: pid_t
  let isZombie: Bool
}

final class ProcessGroupWitness: @unchecked Sendable {
  private let lock = NSLock()
  let processIdentifier: pid_t
  private let descendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)?
  private var reaped = false

  init(
    processIdentifier: pid_t,
    descendantStatusInspector: (@Sendable (pid_t) -> ProcessGroupDescendantStatus)? = nil
  ) {
    self.processIdentifier = processIdentifier
    self.descendantStatusInspector = descendantStatusInspector
  }

  /// The sole process-group signal path. The witness is only reaped after
  /// descendant cleanup completes (and after final SIGKILL when needed), so
  /// every signal is backed by a PID the parent still owns and cannot recycle.
  @discardableResult
  func signalOwnedProcessGroup(
    _ signal: Int32,
    signalObserver: (@Sendable (pid_t, Int32) -> Void)?
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !reaped else { return false }
    signalObserver?(-processIdentifier, signal)
    return kill(-processIdentifier, signal) == 0 || errno == EPERM
  }

  /// Reports group completion without counting the intentionally unreaped
  /// ownership witness. A failed inspection is distinct from an empty group.
  func descendantStatus() -> ProcessGroupDescendantStatus {
    lock.withLock {
      guard !reaped else { return .none }
      if let descendantStatusInspector {
        return descendantStatusInspector(processIdentifier)
      }
      return processGroupDescendantStatus(processGroupIdentifier: processIdentifier)
    }
  }

  /// Called after group termination completes or final SIGKILL was attempted.
  /// Reaping relinquishes the numeric ownership witness and permanently
  /// disables all later group signals.
  func reapAfterTermination() async {
    while true {
      let didReap = lock.withLock {
        guard !reaped else { return true }
        var status: Int32 = 0
        let waitedProcess = waitForWitness(processIdentifier: processIdentifier, status: &status)
        guard waitedProcess == processIdentifier || (waitedProcess == -1 && errno == ECHILD) else {
          return false
        }
        reaped = true
        return true
      }
      if didReap { return }
      await Task.yield()
    }
  }

  private func waitForWitness(processIdentifier: pid_t, status: inout Int32) -> pid_t {
    var waitedProcess: pid_t = -1
    repeat {
      waitedProcess = waitpid(processIdentifier, &status, WNOHANG)
    } while waitedProcess == -1 && errno == EINTR
    return waitedProcess
  }

}

private func processGroupDescendantStatus(processGroupIdentifier: pid_t) -> ProcessGroupDescendantStatus {
  guard let members = processGroupMembers(processGroupIdentifier: processGroupIdentifier) else {
    return .unavailable
  }
  let descendants = members.filter { $0.processIdentifier != processGroupIdentifier }
  guard !descendants.isEmpty else { return .none }
  return descendants.contains(where: { !$0.isZombie }) ? .live : .zombies
}

private func processGroupMembers(processGroupIdentifier: pid_t) -> [ProcessGroupMember]? {
  #if os(Linux)
  return linuxProcessGroupMembers(processGroupIdentifier: processGroupIdentifier)
  #else
  return darwinProcessGroupMembers(processGroupIdentifier: processGroupIdentifier)
  #endif
}

#if os(Linux)
private func linuxProcessGroupMembers(processGroupIdentifier: pid_t) -> [ProcessGroupMember]? {
  guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
  var members: [ProcessGroupMember] = []
  for entry in entries {
    guard let processIdentifier = pid_t(entry) else { continue }
    guard let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
      let closingParenthesis = stat.lastIndex(of: ")")
    else {
      return nil
    }
    let fields = stat[stat.index(after: closingParenthesis)...].split(separator: " ")
    guard fields.count >= 3,
      pid_t(fields[2]) == processGroupIdentifier
    else {
      continue
    }
    members.append(ProcessGroupMember(processIdentifier: processIdentifier, isZombie: fields[0] == "Z"))
  }
  return members
}
#else
private func darwinProcessGroupMembers(processGroupIdentifier: pid_t) -> [ProcessGroupMember]? {
  var managementInformationBase = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
  for _ in 0 ..< 3 {
    var byteCount = 0
    guard sysctl(&managementInformationBase, UInt32(managementInformationBase.count), nil, &byteCount, nil, 0) == 0,
      byteCount > 0
    else {
      return nil
    }
    var processes = [kinfo_proc](
      repeating: kinfo_proc(),
      count: (byteCount / MemoryLayout<kinfo_proc>.stride) + 8
    )
    guard sysctl(
      &managementInformationBase,
      UInt32(managementInformationBase.count),
      &processes,
      &byteCount,
      nil,
      0
    ) == 0 else {
      if errno == ENOMEM { continue }
      return nil
    }
    return processes.prefix(byteCount / MemoryLayout<kinfo_proc>.stride).compactMap { process in
      guard process.kp_eproc.e_pgid == processGroupIdentifier else { return nil }
      return ProcessGroupMember(
        processIdentifier: process.kp_proc.p_pid,
        isZombie: process.kp_proc.p_stat == SZOMB
      )
    }
  }
  return nil
}
#endif

private func gatewayProcessExitCode(from waitStatus: Int32) -> Int32 {
  let terminationSignal = waitStatus & 0x7F
  if terminationSignal != 0 && terminationSignal != 0x7F {
    return terminationSignal
  }
  return (waitStatus >> 8) & 0xFF
}

/// Bridges the child waitpid callback to structured concurrency.
final class ProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var continuation: CheckedContinuation<Int32, Never>?
  func finish(status: Int32) {
    lock.lock()
    self.status = status
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: status)
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if let status {
          continuation.resume(returning: status)
        } else {
          self.continuation = continuation
        }
      }
    }
  }
}

/// Owns all gateway stop paths, including a post-reap path that never targets
/// the direct PID after it can have been reused by another process.
final class ProcessTerminator: @unchecked Sendable {
  private let lock = NSLock()
  private let input: FileHandle
  private let output: FileHandle
  private let error: FileHandle
  private let processGroupWitness: ProcessGroupWitness
  private let terminationGraceNanoseconds: UInt64
  private let processGroupPollIntervalWaiter: (@Sendable () async -> Void)?
  private let signalObserver: (@Sendable (pid_t, Int32) -> Void)?
  private var terminationRequested = false
  private var forceKillRequested = false
  private var deadlineExceeded = false

  init(input: FileHandle, output: FileHandle, error: FileHandle,
       processGroupWitness: ProcessGroupWitness,
       terminationGraceNanoseconds: UInt64,
       processGroupPollIntervalWaiter: (@Sendable () async -> Void)?,
       signalObserver: (@Sendable (pid_t, Int32) -> Void)?) {
    self.input = input
    self.output = output
    self.error = error
    self.processGroupWitness = processGroupWitness
    self.terminationGraceNanoseconds = terminationGraceNanoseconds
    self.processGroupPollIntervalWaiter = processGroupPollIntervalWaiter
    self.signalObserver = signalObserver
  }

  var didExceedDeadline: Bool {
    lock.lock()
    defer { lock.unlock() }
    return deadlineExceeded
  }

  func terminateForOutputLimit() { requestTermination(deadlineExceeded: false) }
  func terminateForDeadline() { requestTermination(deadlineExceeded: true) }
  func cancel() { requestTermination(deadlineExceeded: false) }

  func terminateRemainingProcessGroup() async {
    if beginProcessGroupTermination() {
      try? input.close()
      _ = processGroupWitness.signalOwnedProcessGroup(SIGTERM, signalObserver: signalObserver)
      scheduleFinalGroupCleanup()
    }
    let clock = ContinuousClock()
    let graceDeadline = clock.now + .nanoseconds(Int64(clamping: terminationGraceNanoseconds))
    var didRequestFinalKill = false
    while true {
      switch processGroupWitness.descendantStatus() {
      case .none:
        await processGroupWitness.reapAfterTermination()
        return
      case .live where !didRequestFinalKill && clock.now >= graceDeadline:
        forceKillRemainingProcessGroup()
        didRequestFinalKill = true
      case .live, .zombies, .unavailable:
        break
      }
      await waitForProcessGroupPollInterval()
    }
  }

  private func waitForProcessGroupPollInterval() async {
    if let processGroupPollIntervalWaiter {
      await processGroupPollIntervalWaiter()
      return
    }
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(10)) {
        continuation.resume()
      }
    }
  }

  @discardableResult
  private func requestTermination(deadlineExceeded: Bool, closeReadEnds: Bool = true) -> Bool {
    let shouldTerminate = lock.withLock {
      self.deadlineExceeded = self.deadlineExceeded || deadlineExceeded
      guard !terminationRequested else { return false }
      terminationRequested = true
      return true
    }
    guard shouldTerminate else { return false }
    try? input.close()
    if closeReadEnds {
      try? output.close()
      try? error.close()
    }
    let didSignal = processGroupWitness.signalOwnedProcessGroup(SIGTERM, signalObserver: signalObserver)
    guard didSignal else { return false }
    scheduleFinalGroupCleanup()
    return true
  }

  private func scheduleFinalGroupCleanup() {
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + .nanoseconds(Int(clamping: terminationGraceNanoseconds))
    ) {
      switch self.processGroupWitness.descendantStatus() {
      case .live, .unavailable:
        self.forceKillRemainingProcessGroup()
      case .none, .zombies:
        break
      }
    }
  }

  private func beginProcessGroupTermination() -> Bool {
    lock.withLock {
      guard !terminationRequested else { return false }
      terminationRequested = true
      return true
    }
  }

  private func forceKillRemainingProcessGroup() {
    lock.lock()
    guard !forceKillRequested else {
      lock.unlock()
      return
    }
    forceKillRequested = true
    lock.unlock()
    _ = processGroupWitness.signalOwnedProcessGroup(SIGKILL, signalObserver: signalObserver)
  }
}
