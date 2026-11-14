import Foundation

/// Application settings persisted in the note store's sqlite database (the
/// `app_settings` table), so preferences like the web UI's font scale follow
/// the store rather than one browser's localStorage. Values are JSON
/// documents keyed by a short setting name (e.g. "web").

public extension NoteService {
  /// The stored JSON document for a setting key, or nil when unset.
  func appSetting(key: String) throws -> String? {
    let normalized = try Self.normalizedSettingKey(key)
    return try driver.withDatabase { database in
      try database.query(
        "SELECT json(value_json) AS value_json FROM app_settings WHERE setting_key = ? LIMIT 1",
        bindings: [.text(normalized)]
      ).first?["value_json"] ?? nil
    }
  }

  /// Stores a setting document (must be valid JSON) and returns the stored
  /// text. The whole document is replaced; merging is the caller's concern.
  @discardableResult
  func setAppSetting(key: String, valueJSON: String) throws -> String {
    let normalized = try Self.normalizedSettingKey(key)
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

  internal static func normalizedSettingKey(_ key: String) throws -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64,
      trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    else {
      throw NoteServiceError.invalidInput(
        "setting key must be 1-64 letters, numbers, '-' or '.'"
      )
    }
    return trimmed
  }
}
