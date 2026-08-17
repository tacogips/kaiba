import Foundation

/// A typed wrapper around one of the store's opaque string identifiers.
///
/// Every entity in Kaiba is addressed by a string id, and before these types
/// existed every one of them was spelled `String`. Nothing stopped a note id
/// from being passed where a notebook id was expected, and the mistake only
/// surfaced as an empty query result at runtime. Each id kind is its own type
/// here, so the compiler rejects the mixup.
///
/// The wrapper is deliberately thin: it carries the raw string unchanged, and
/// it encodes as that bare string, so database columns, GraphQL values, and
/// JSON payloads keep exactly the shape they had before.
///
/// Conversion is always explicit — there is no `ExpressibleByStringLiteral`
/// conformance — so a raw string enters the type system only where a boundary
/// (SQL row, GraphQL argument, HTTP path) genuinely hands one over.
public protocol KaibaIdentifier: RawRepresentable, Hashable, Comparable, Codable, Sendable,
  CustomStringConvertible
where RawValue == String {
  init(_ rawValue: String)

  /// Leading word of a freshly minted id. It is part of the stored value and
  /// keeps ids self-describing wherever they are printed.
  static var generatedPrefix: String { get }
}

extension KaibaIdentifier {
  public init?(rawValue: String) {
    self.init(rawValue)
  }

  /// Builds an identifier from caller-supplied text, rejecting blank input.
  /// Boundaries that parse ids out of requests use this so that `""` and
  /// whitespace never reach the store as a lookup key.
  public init?(validating rawValue: String) {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    self.init(trimmed)
  }

  public var isEmpty: Bool {
    rawValue.isEmpty
  }

  /// Mints a fresh identifier: prefix, minting time, and a UUID, which is the
  /// shape every id in the store has had since the first schema.
  public static func generate() -> Self {
    let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    return Self("\(generatedPrefix)-\(milliseconds)-\(UUID().uuidString.lowercased())")
  }

  public var description: String {
    rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// Encodes as the bare string rather than as a wrapper object, keeping the
  /// GraphQL and HTTP payload shapes identical to the pre-newtype format.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Identifies a note page.
public struct NoteID: KaibaIdentifier {
  public static let generatedPrefix = "note"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a notebook.
public struct NotebookID: KaibaIdentifier {
  public static let generatedPrefix = "notebook"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a library (`design-docs/specs/library.md`).
public struct LibraryID: KaibaIdentifier {
  public static let generatedPrefix = "library"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies an account (`design-docs/specs/multi-user.md`).
public struct UserID: KaibaIdentifier {
  public static let generatedPrefix = "user"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a tag.
public struct TagID: KaibaIdentifier {
  public static let generatedPrefix = "tag"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a tag class, the namespace a tag belongs to.
public struct TagClassID: KaibaIdentifier {
  public static let generatedPrefix = "tag-class"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

extension TagClassID {
  /// The tag classes every store is seeded with (`NoteStoreSchema`). Code that
  /// singles one out — folder tags shape the notebook tree, document-kind tags
  /// mark notebook kinds — names it here instead of repeating the literal.
  public static let contentKind = TagClassID("content-kind")
  public static let person = TagClassID("person")
  public static let year = TagClassID("year")
  public static let event = TagClassID("event")
  public static let documentKind = TagClassID("document-kind")
  public static let topic = TagClassID("topic")
  public static let folder = TagClassID("folder")
  public static let source = TagClassID("source")
  public static let workflow = TagClassID("workflow")
}

/// Identifies a stored file blob.
public struct FileID: KaibaIdentifier {
  public static let generatedPrefix = "file"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a memo attached to a note or notebook.
public struct CommentID: KaibaIdentifier {
  public static let generatedPrefix = "comment"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a registered API client credential.
public struct APIClientID: KaibaIdentifier {
  public static let generatedPrefix = "client"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a configured auto action.
public struct AutoActionID: KaibaIdentifier {
  public static let generatedPrefix = "auto-action"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies a single dispatch attempt of an auto action.
public struct AutoActionDispatchID: KaibaIdentifier {
  public static let generatedPrefix = "auto-action-dispatch"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Identifies the external workflow an auto action dispatches to.
public struct WorkflowID: KaibaIdentifier {
  public static let generatedPrefix = "workflow"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

extension SQLiteValue {
  /// Binds an identifier as its raw text.
  public static func id(_ value: some KaibaIdentifier) -> SQLiteValue {
    .text(value.rawValue)
  }

  public static func optionalID<Identifier: KaibaIdentifier>(_ value: Identifier?) -> SQLiteValue {
    value.map { .text($0.rawValue) } ?? .null
  }
}

extension SQLiteRow {
  /// Reads an identifier column, returning nil when the column is absent or
  /// SQL NULL.
  public func identifier<Identifier: KaibaIdentifier>(
    _ column: String,
    as type: Identifier.Type = Identifier.self
  ) -> Identifier? {
    self[column].map(Identifier.init)
  }
}

extension Sequence where Element: KaibaIdentifier {
  /// The raw strings behind a list of identifiers, for SQL binding and for
  /// payloads that carry plain strings.
  public var rawValues: [String] {
    map(\.rawValue)
  }

  public var sqliteBindings: [SQLiteValue] {
    map { SQLiteValue.text($0.rawValue) }
  }
}
