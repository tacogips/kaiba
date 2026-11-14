import Foundation

/// Outbound mail, used so far only by email login. A protocol because delivery
/// is an integration: a local install has no mail infrastructure and wants the
/// code in the log, while a hosted one sends it for real
/// (`design-docs/specs/note-api-auth.md`).
public protocol KaibaMailSending: Sendable {
  func send(_ message: KaibaMailMessage) async throws
}

public struct KaibaMailMessage: Equatable, Sendable {
  public var to: String
  public var from: String
  public var subject: String
  public var text: String
  /// Repeating a send with the same key must not deliver a second copy. Resend
  /// honors this for 24 hours, which covers a retried login request.
  public var idempotencyKey: String?

  public init(
    to: String,
    from: String,
    subject: String,
    text: String,
    idempotencyKey: String? = nil
  ) {
    self.to = to
    self.from = from
    self.subject = subject
    self.text = text
    self.idempotencyKey = idempotencyKey
  }
}

public enum KaibaMailError: Error, Equatable, Sendable, CustomStringConvertible {
  case unavailable(String)
  case failed(String)

  public var description: String {
    switch self {
    case let .unavailable(detail): "mail sender is unavailable: \(detail)"
    case let .failed(detail): "mail delivery failed: \(detail)"
    }
  }
}

/// The default sender: writes the message to stderr instead of delivering it,
/// so a machine-local install can complete a login with no mail account. It is
/// explicitly not silent — an operator who has not configured delivery should
/// see where the code went.
public struct LogMailSender: KaibaMailSending {
  public init() {}

  public func send(_ message: KaibaMailMessage) async throws {
    let line = """
      [kaiba-mail] no delivery configured; message not sent
        to: \(message.to)
        subject: \(message.subject)
        \(message.text.replacingOccurrences(of: "\n", with: "\n    "))

      """
    FileHandle.standardError.write(Data(line.utf8))
  }
}
