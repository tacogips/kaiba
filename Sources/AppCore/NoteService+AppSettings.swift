import Foundation

/// Application settings persisted in the note store's sqlite database (the
/// `app_settings` table), so preferences like the web UI's font scale follow
/// the store rather than one browser's localStorage. Values are JSON
/// documents keyed by a short setting name (e.g. "web").

public extension NoteService {
  /// Keys under this prefix hold credentials (the JWT signing secret lives at
  /// `auth.jwt.secret`) and must never be reachable through the caller-facing
  /// `appSetting`/`setAppSetting` surface, which is exposed over GraphQL with
  /// no admin gate. Internal code reaches them through the `reserved` variants.
  static let reservedSettingKeyPrefix = "auth."

  /// The stored JSON document for a setting key, or nil when unset. Refuses
  /// reserved (`auth.`) keys so a client cannot read the signing secret.
  func appSetting(key: String) throws -> String? {
    try appSetting(key: key, allowReserved: false)
  }

  /// Stores a setting document (must be valid JSON) and returns the stored
  /// text. The whole document is replaced; merging is the caller's concern.
  /// Refuses reserved (`auth.`) keys so a client cannot forge the signing key.
  @discardableResult
  func setAppSetting(key: String, valueJSON: String) throws -> String {
    try setAppSetting(key: key, valueJSON: valueJSON, allowReserved: false)
  }

  internal func appSetting(key: String, allowReserved: Bool) throws -> String? {
    let normalized = try Self.normalizedSettingKey(key, allowReserved: allowReserved)
    return try driver.withDatabase { database in
      try database.query(
        "SELECT json(value_json) AS value_json FROM app_settings WHERE setting_key = ? LIMIT 1",
        bindings: [.text(normalized)]
      ).first?["value_json"] ?? nil
    }
  }

  @discardableResult
  internal func setAppSetting(key: String, valueJSON: String, allowReserved: Bool) throws -> String {
    let normalized = try Self.normalizedSettingKey(key, allowReserved: allowReserved)
    guard (try? JSONValue(parsing: valueJSON)) != nil else {
      throw NoteServiceError.invalidInput("setting value must be valid JSON")
    }
    guard valueJSON.utf8.count <= 64 * 1024 else {
      throw NoteServiceError.invalidInput("setting value must be 64KB or smaller")
    }
    try driver.withDatabase { database in
      try database.execute(
        """
        INSERT INTO app_settings (setting_key, value_json, updated_at)
        VALUES (?, jsonb(?), ?)
        ON CONFLICT(setting_key) DO UPDATE SET
          value_json = excluded.value_json,
          updated_at = excluded.updated_at
        """,
        bindings: [.text(normalized), .text(valueJSON), .text(NoteStoreClock.system.now())]
      )
    }
    return valueJSON
  }

  internal static func normalizedSettingKey(_ key: String, allowReserved: Bool = false) throws -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64,
      trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    else {
      throw NoteServiceError.invalidInput(
        "setting key must be 1-64 letters, numbers, '-' or '.'"
      )
    }
    // The reserved namespace is refused with the same "not found"-shaped error
    // the public API already uses for a bad key, so the surface never confirms
    // that a credential key exists.
    guard allowReserved || !trimmed.hasPrefix(reservedSettingKeyPrefix) else {
      throw NoteServiceError.invalidInput(
        "setting key must be 1-64 letters, numbers, '-' or '.'"
      )
    }
    return trimmed
  }
}
