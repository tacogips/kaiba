import Foundation

/// A validated text or image attachment supplied with an agent chat turn.
public struct AgentChatAttachment: Equatable, Sendable {
  public let data: Data
  public let mediaType: String
  public let originalFilename: String

  public init(data: Data, mediaType: String, originalFilename: String) {
    self.data = data
    self.mediaType = mediaType
    self.originalFilename = originalFilename
  }
}

public enum AgentChatAttachmentValidation {
  public static let maximumFiles = 4
  public static let maximumAggregateBytes = 1_048_576
  public static let maximumFilenameBytes = 255
  public static let allowedMediaTypes: Set<String> = [
    "text/plain", "text/markdown", "text/csv", "text/tab-separated-values",
    "application/json", "application/xml", "application/yaml", "application/x-yaml",
    "image/png", "image/jpeg"
  ]

  public static func validate(
    data: Data,
    declaredMediaType: String,
    originalFilename: String
  ) throws -> AgentChatAttachment {
    let mediaType = declaredMediaType.split(separator: ";", maxSplits: 1).first
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    guard allowedMediaTypes.contains(mediaType) else {
      throw NoteServiceError.invalidInput("unsupported chat attachment media type")
    }
    guard !originalFilename.isEmpty,
      originalFilename.utf8.count <= maximumFilenameBytes,
      !originalFilename.contains("/"), !originalFilename.contains("\\"),
      !originalFilename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw NoteServiceError.invalidInput("invalid chat attachment filename")
    }
    if mediaType.hasPrefix("image/") {
      guard validChatImage(data, mediaType: mediaType) else {
        throw NoteServiceError.invalidInput("chat image attachment does not match its declared format")
      }
    } else if data.isEmpty || String(data: data, encoding: .utf8) == nil {
      throw NoteServiceError.invalidInput("chat attachments must be non-empty UTF-8 text")
    }
    return AgentChatAttachment(data: data, mediaType: mediaType, originalFilename: originalFilename)
  }

  public static func validate(_ attachments: [AgentChatAttachment]) throws {
    guard attachments.count <= maximumFiles else {
      throw NoteServiceError.invalidInput("at most four chat attachments are allowed")
    }
    guard attachments.reduce(0, { $0 + $1.data.count }) <= maximumAggregateBytes else {
      throw NoteServiceError.invalidInput("chat attachments exceed 1 MiB")
    }
    for attachment in attachments {
      _ = try validate(data: attachment.data, declaredMediaType: attachment.mediaType,
        originalFilename: attachment.originalFilename)
    }
    let identities = attachments.map { "\($0.originalFilename)\u{0}\(sha256Hex($0.data))" }
    guard Set(identities).count == identities.count else {
      throw NoteServiceError.invalidInput("duplicate chat attachment")
    }
  }
}

func validChatImage(_ data: Data, mediaType: String) -> Bool {
  switch mediaType {
  case "image/png": return data.count > 8 && data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
  case "image/jpeg": return data.count > 4 && data.starts(with: [255, 216, 255]) && data.suffix(2) == Data([255, 217])
  default: return false
  }
}

struct ChatFilePromptContents {
  var markdown = ""
  var images: [AgentInvocationImage] = []
}
