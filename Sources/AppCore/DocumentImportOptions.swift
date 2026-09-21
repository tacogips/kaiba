import Foundation

public enum DocumentOCREngine: String, Codable, Sendable {
  case vision
  case googleDocumentAI = "google-document-ai"
  case agentGateway = "agent-gateway"
}

public enum DocumentOCRPageLimit: Equatable, Sendable, Codable {
  case all
  case first(Int)

  public var maximum: Int? {
    switch self {
    case .all: return nil
    case .first(let count): return count
    }
  }

  public static func parse(_ value: String) throws -> Self {
    if value == "all" { return .all }
    guard let count = Int(value), count >= 0 else {
      throw NoteServiceError.invalidInput("maximum OCR pages must be a nonnegative integer or all")
    }
    return .first(count)
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let count = try? value.decode(Int.self), count >= 0 {
      self = .first(count)
    } else if let text = try? value.decode(String.self), text == "all" {
      self = .all
    } else {
      throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a nonnegative integer or all")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .all: try value.encode("all")
    case .first(let count):
      guard count >= 0 else {
        throw EncodingError.invalidValue(count, .init(codingPath: encoder.codingPath, debugDescription: "Negative OCR page limit"))
      }
      try value.encode(count)
    }
  }
}
