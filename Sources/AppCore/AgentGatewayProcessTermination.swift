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
/// The three outcomes the Linux enumeration contract distinguishes for one
/// `/proc/<pid>/stat` read. `vanished` is a deliberate skip, not a failure.
private enum LinuxProcessStatReadOutcome {
  case contents([UInt8])
  case vanished
  case failure
}

/// Reads `/proc/<pid>/stat` through raw syscalls so the discrimination is made
/// from the errno of the failing call, at the instant it fails.
///
/// Exactly two errnos mean the PID vanished, and both are honored at **both**
/// syscall sites. `ENOENT` means the `/proc/<pid>` directory is already gone.
/// `ESRCH` means the directory still exists but procfs could not resolve it to
/// a task: the kernel's `get_proc_task`/`get_pid_task` lookup found nothing, so
/// the process is gone and cannot possibly be a live descendant. Either one
/// skips the entry, and the enumeration stays complete without it. Every other
/// errno is a real inspection failure on a process that still exists and must
/// be reported as an incomplete enumeration (`unavailable`). `EINTR` is retried
/// at both the open and the read rather than classified.
///
/// `ESRCH` matters in practice, not only in principle. It is the errno a task
/// reaped between a successful open and the read produces, and that window is
/// not the negligible microsecond race an earlier revision of this code assumed:
/// measured under heavy PID churn on Linux, treating `ESRCH` as a failure made
/// `unavailable` the outcome of 1.56% of enumerations. Honoring it at the read
/// site alone still leaves the open site producing `ESRCH`, so both are covered
/// or neither is. The skip is deliberately not widened past these two errnos.
///
/// Discrimination is deliberately not made by re-testing the path for
/// existence after a failed read. A re-check is a second observation at a later
/// instant, and a process that exits between a genuine read failure and that
/// re-check would be reclassified as vanished, which is the fail-open
/// direction. `ENOENT` and `ESRCH` are not that: each is read in band, from the
/// syscall that failed, at the instant it failed. Foundation's convenience read
/// is likewise unusable here: it discards the error outright, and inspecting an
/// `NSError` domain or code afterwards reports Foundation's own classification
/// through a mapping that is not guaranteed to preserve the distinction this
/// contract turns on.
private func linuxProcessStatContents(path: String) -> LinuxProcessStatReadOutcome {
  // `errno` is captured inside the same scope as the call that set it, so no
  // intervening work (buffer deallocation, ARC traffic) can clobber the value
  // the classification turns on.
  var descriptor: Int32 = -1
  var openError: Int32 = 0
  repeat {
    (descriptor, openError) = path.withCString { path -> (Int32, Int32) in
      let result = open(path, O_RDONLY | O_CLOEXEC)
      return (result, result == -1 ? errno : 0)
    }
  } while descriptor == -1 && openError == EINTR
  guard descriptor >= 0 else {
    // Both errnos prove the task is gone, so neither can hide a live
    // descendant. A zombie keeps its `/proc/<pid>` entry until it is reaped,
    // so the skip cannot hide a zombie either.
    return openError == ENOENT || openError == ESRCH ? .vanished : .failure
  }
  defer { close(descriptor) }
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let (readCount, readError) = buffer.withUnsafeMutableBytes { buffer -> (Int, Int32) in
      let result = read(descriptor, buffer.baseAddress, buffer.count)
      return (result, result == -1 ? errno : 0)
    }
    if readCount > 0 {
      bytes.append(contentsOf: buffer[0 ..< readCount])
      continue
    }
    if readCount == 0 { break }
    if readError == EINTR { continue }
    // The task was reaped between the open and this read. Any bytes gathered so
    // far describe a process that no longer exists, so they are discarded with
    // the entry rather than parsed.
    if readError == ESRCH { return .vanished }
    return .failure
  }
  return .contents(bytes)
}

/// Splits the fields that follow the `comm` field of a `/proc/<pid>/stat` line.
///
/// Only the tail after the last `)` is decoded. `comm` is the one part of the
/// line that carries arbitrary process-supplied bytes, and decoding it would
/// force a choice between a lossy replacement decode and reporting every
/// process with a non-UTF-8 name as an enumeration failure. The tail the
/// contract actually reads is kernel-generated ASCII, so an undecodable tail is
/// a genuine cause-2 inspection failure rather than a routine occurrence.
private func linuxProcessStatFieldsAfterCommand(_ bytes: [UInt8]) -> [Substring]? {
  guard let closingParenthesis = bytes.lastIndex(of: UInt8(ascii: ")")) else { return nil }
  let tail = Array(bytes[bytes.index(after: closingParenthesis)...])
  guard let fields = String(bytes: tail, encoding: .utf8) else { return nil }
  return fields.split(separator: " ")
}

private func linuxProcessGroupMembers(processGroupIdentifier: pid_t) -> [ProcessGroupMember]? {
  // Cause 1: nothing was enumerated, so nothing may be concluded.
  guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
  var members: [ProcessGroupMember] = []
  for entry in entries {
    guard let processIdentifier = pid_t(entry) else { continue }
    let stat: [UInt8]
    switch linuxProcessStatContents(path: "/proc/\(entry)/stat") {
    case .contents(let contents):
      stat = contents
    case .vanished:
      continue
    case .failure:
      return nil
    }
    // Cause 2: the stat file existed and was read, but yields no parseable line.
    guard let fields = linuxProcessStatFieldsAfterCommand(stat) else { return nil }
    guard fields.count >= 3 else { return nil }
    // Structural state invariant, not an allowlist: the token must be present
    // and exactly one character. An enumerated set of known process states
    // would fail in the dangerous direction, because an unlisted-but-valid
    // state would make `unavailable` the normal Linux result.
    let state = fields[0]
    guard state.count == 1 else { return nil }
    // The former compound guard sent two opposite-safety outcomes to one
    // `continue`. An unparseable pgid is cause 2 and fails closed; a pgid that
    // parses and simply names another group is an ordinary non-member skip.
    guard let memberProcessGroupIdentifier = pid_t(fields[2]) else { return nil }
    guard memberProcessGroupIdentifier == processGroupIdentifier else { continue }
    members.append(ProcessGroupMember(processIdentifier: processIdentifier, isZombie: state == "Z"))
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
  private let scheduledDescendantStatusObserver: (@Sendable (ProcessGroupDescendantStatus) -> Void)?
  private var terminationRequested = false
  private var forceKillRequested = false
  private var deadlineExceeded = false

  init(input: FileHandle, output: FileHandle, error: FileHandle,
       processGroupWitness: ProcessGroupWitness,
       terminationGraceNanoseconds: UInt64,
       processGroupPollIntervalWaiter: (@Sendable () async -> Void)?,
       signalObserver: (@Sendable (pid_t, Int32) -> Void)?,
       scheduledDescendantStatusObserver: (@Sendable (ProcessGroupDescendantStatus) -> Void)? = nil) {
    self.input = input
    self.output = output
    self.error = error
    self.processGroupWitness = processGroupWitness
    self.terminationGraceNanoseconds = terminationGraceNanoseconds
    self.processGroupPollIntervalWaiter = processGroupPollIntervalWaiter
    self.signalObserver = signalObserver
    self.scheduledDescendantStatusObserver = scheduledDescendantStatusObserver
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
      // Observation seam, not an injection seam: the real inspector still runs
      // and still decides, and the observer only reports what it decided. The
      // scheduled probe is otherwise the one state evaluation in this contract
      // whose outcome leaves no trace, so `none` and `zombies` are
      // indistinguishable from outside without this report.
      let status = self.processGroupWitness.descendantStatus()
      self.scheduledDescendantStatusObserver?(status)
      switch status {
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
