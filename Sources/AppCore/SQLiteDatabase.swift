import Foundation
#if os(Linux)
import CKaibaSQLite3
#else
import SQLite3
#endif

public enum SQLiteOpenMode: Sendable {
  case readOnly
  case strictReadOnly
  case strictReadOnlyWithImmutableFallback
  case readWriteCreate
}

public struct SQLiteOpenOptions: Sendable {
  public var enableWAL: Bool
  public var enableForeignKeys: Bool
  public var busyTimeoutMilliseconds: Int32?
  public var requireJSONB: Bool
  public var requireFTS5: Bool

  public init(
    enableWAL: Bool = true,
    enableForeignKeys: Bool = true,
    busyTimeoutMilliseconds: Int32? = 3_000,
    requireJSONB: Bool = true,
    requireFTS5: Bool = false
  ) {
    self.enableWAL = enableWAL
    self.enableForeignKeys = enableForeignKeys
    self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    self.requireJSONB = requireJSONB
    self.requireFTS5 = requireFTS5
  }

  public static let writableDefault = SQLiteOpenOptions()
  public static let readOnlyDefault = SQLiteOpenOptions(enableWAL: false)
}

public enum SQLiteErrorOperation: String, Sendable {
  case open
  case execute
  case query
  case bind
  case jsonBUnavailable
  case fts5Unavailable
}

public struct SQLiteError: Error, Equatable, Sendable {
  public var operation: SQLiteErrorOperation
  public var code: Int32?
  public var message: String
  public var sql: String?

  public init(operation: SQLiteErrorOperation, code: Int32?, message: String, sql: String? = nil) {
    self.operation = operation
    self.code = code
    self.message = message
    self.sql = sql
  }
}

public enum SQLiteValue: Sendable {
  case text(String)
  case int(Int64)
  case double(Double)
  case null

  public static func optionalText(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
  }

  public static func optionalInt(_ value: Int?) -> SQLiteValue {
    value.map { .int(Int64($0)) } ?? .null
  }

  public static func optionalDouble(_ value: Double?) -> SQLiteValue {
    value.map(SQLiteValue.double) ?? .null
  }
}

public struct SQLiteRow: Equatable, Sendable {
  private var values: [String: String?]

  public init(values: [String: String?]) {
    self.values = values
  }

  public subscript(_ column: String) -> String? {
    values[column] ?? nil
  }

  public func string(_ column: String, nullValue: String = "") -> String {
    self[column] ?? nullValue
  }
}

public final class SQLiteDatabase: @unchecked Sendable {
  public let path: String?
  private let handle: OpaquePointer?
  private let ownsHandle: Bool
  private let remote: TursoHTTPDatabase?

  private init(
    path: String?,
    handle: OpaquePointer?,
    ownsHandle: Bool,
    remote: TursoHTTPDatabase? = nil
  ) {
    self.path = path
    self.handle = handle
    self.ownsHandle = ownsHandle
    self.remote = remote
  }

  deinit {
    if ownsHandle {
      sqlite3_close(handle)
    }
  }

  public static func open(
    path: String,
    mode: SQLiteOpenMode = .readWriteCreate,
    options: SQLiteOpenOptions = .writableDefault
  ) throws -> SQLiteDatabase {
    switch mode {
    case .readOnly:
      do {
        let database = try openConfiguredDatabase(path: path, flags: SQLITE_OPEN_READONLY, options: options)
        try database.verifyUsableReadConnection()
        return database
      } catch let error as SQLiteError where shouldFallbackToReadWriteOpen(path: path, error: error) {
        return try openConfiguredDatabase(path: path, flags: SQLITE_OPEN_READWRITE, options: options)
      }
    case .strictReadOnly:
      let database = try openConfiguredDatabase(path: path, flags: SQLITE_OPEN_READONLY, options: options)
      try database.verifyUsableReadConnection()
      return database
    case .strictReadOnlyWithImmutableFallback:
      if shouldUseImmutableReadOnlyOpen(path: path) {
        let database = try openConfiguredDatabase(
          path: immutableReadOnlyURI(path: path),
          flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
          options: options,
          reportedPath: path
        )
        try database.verifyUsableReadConnection()
        return database
      }
      let database = try openConfiguredDatabase(path: path, flags: SQLITE_OPEN_READONLY, options: options)
      try database.verifyUsableReadConnection()
      return database
    case .readWriteCreate:
      let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return try openConfiguredDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, options: options)
    }
  }

  private static func openConfiguredDatabase(
    path: String,
    flags: Int32,
    options: SQLiteOpenOptions,
    reportedPath: String? = nil
  ) throws -> SQLiteDatabase {
    let diagnosticPath = reportedPath ?? path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
      let message = db.map(errorMessage) ?? "sqlite open failed"
      let code = db.map(sqlite3_errcode)
      if let db {
        sqlite3_close(db)
      }
      throw SQLiteError(
        operation: .open,
        code: code,
        message: "failed to open sqlite database at \(diagnosticPath): \(message)"
      )
    }
    let database = SQLiteDatabase(path: diagnosticPath, handle: opened, ownsHandle: true)
    try database.configure(options)
    return database
  }

  private static func shouldFallbackToReadWriteOpen(path: String, error: SQLiteError) -> Bool {
    guard error.code == SQLITE_CANTOPEN,
          FileManager.default.fileExists(atPath: path),
          FileManager.default.isWritableFile(atPath: path) else {
      return false
    }
    return true
  }

  private static func shouldUseImmutableReadOnlyOpen(path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
      && !FileManager.default.fileExists(atPath: path + "-wal")
  }

  private static func immutableReadOnlyURI(path: String) -> String {
    URL(fileURLWithPath: path).absoluteString + "?mode=ro&immutable=1"
  }

  public static func borrowing(_ handle: OpaquePointer?, path: String? = nil) -> SQLiteDatabase {
    SQLiteDatabase(path: path, handle: handle, ownsHandle: false)
  }

  static func remote(path: String, database: TursoHTTPDatabase) -> SQLiteDatabase {
    SQLiteDatabase(path: path, handle: nil, ownsHandle: false, remote: database)
  }

  public func transaction<T>(
    begin: String = "BEGIN IMMEDIATE",
    _ body: (SQLiteDatabase) throws -> T
  ) throws -> T {
    try execute(begin)
    do {
      let value = try body(self)
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
    _ = try executeAndReturnChangedRowCount(sql, bindings: bindings)
  }

  @discardableResult
  public func executeAndReturnChangedRowCount(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
    if let remote {
      return try remote.execute(sql, bindings: bindings).affectedRowCount
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError(operation: .execute, sql: sql)
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(bindings, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw sqliteError(operation: .execute, sql: sql)
    }
    return Int(sqlite3_changes(handle))
  }

  public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
    if let remote {
      return try remote.execute(sql, bindings: bindings).rows
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw sqliteError(operation: .query, sql: sql)
    }
    defer {
      sqlite3_finalize(statement)
    }
    try bind(bindings, to: statement)

    var rows: [SQLiteRow] = []
    while true {
      let result = sqlite3_step(statement)
      switch result {
      case SQLITE_ROW:
        rows.append(row(from: statement))
      case SQLITE_DONE:
        return rows
      default:
        throw sqliteError(operation: .query, sql: sql)
      }
    }
  }

  public func requireJSONBAvailable() throws {
    let rows = try query("SELECT typeof(jsonb('{}')) AS storage_type, json_valid(jsonb('{}'), 8) AS valid_jsonb")
    guard rows.first?["storage_type"] == "blob", rows.first?["valid_jsonb"] == "1" else {
      throw SQLiteError(
        operation: .jsonBUnavailable,
        code: nil,
        message: "sqlite JSONB support is unavailable"
      )
    }
  }

  public func requireFTS5Available() throws {
    do {
      try runFTS5Probe(createSQL: "CREATE VIRTUAL TABLE %@ USING fts5(value)")
    } catch let error as SQLiteError {
      throw SQLiteError(
        operation: .fts5Unavailable,
        code: error.code,
        message: "sqlite FTS5 support is unavailable: \(error.message)"
      )
    }
  }

  public func requireFTS5TrigramAvailable() throws {
    do {
      try runFTS5Probe(createSQL: "CREATE VIRTUAL TABLE %@ USING fts5(value, tokenize='trigram')")
    } catch let error as SQLiteError {
      throw SQLiteError(
        operation: .fts5Unavailable,
        code: error.code,
        message: "sqlite FTS5 trigram tokenizer support is unavailable: \(error.message)"
      )
    }
  }

  public func tableExists(_ name: String) throws -> Bool {
    let rows = try query(
      "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      bindings: [.text(name)]
    )
    return rows.first?["present"] != nil
  }

  private func runFTS5Probe(createSQL: String) throws {
    let tableName = "kaiba_fts5_probe_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    defer {
      try? execute("DROP TABLE IF EXISTS \(tableName)")
    }
    try execute(String(format: createSQL, tableName))
  }

  public func tableColumnNames(_ tableName: String) throws -> Set<String> {
    let rows = try query("PRAGMA table_info(\(tableName))")
    return Set(rows.compactMap { $0["name"] })
  }

  private func configure(_ options: SQLiteOpenOptions) throws {
    if let busyTimeoutMilliseconds = options.busyTimeoutMilliseconds {
      sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
    }
    if options.enableForeignKeys {
      try execute("PRAGMA foreign_keys=ON")
    }
    if options.enableWAL {
      _ = try query("PRAGMA journal_mode=WAL")
    }
    if options.requireJSONB {
      try requireJSONBAvailable()
    }
    if options.requireFTS5 {
      try requireFTS5Available()
    }
  }

  private func verifyUsableReadConnection() throws {
    _ = try query("PRAGMA schema_version")
  }

  private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer?) throws {
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case let .text(value):
        result = sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
      case let .int(value):
        result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
      case let .double(value):
        result = sqlite3_bind_double(statement, index, value)
      case .null:
        result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else {
        throw SQLiteError(
          operation: .bind,
          code: result,
          message: messageWithPath("sqlite bind failed at parameter \(index)")
        )
      }
    }
  }

  private func row(from statement: OpaquePointer?) -> SQLiteRow {
    var values: [String: String?] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      guard let name = sqlite3_column_name(statement, index) else {
        continue
      }
      let key = String(cString: name)
      if sqlite3_column_type(statement, index) == SQLITE_NULL {
        values[key] = nil
      } else if let text = sqlite3_column_text(statement, index) {
        values[key] = String(cString: text)
      } else {
        values[key] = nil
      }
    }
    return SQLiteRow(values: values)
  }

  private func sqliteError(operation: SQLiteErrorOperation, sql: String?) -> SQLiteError {
    SQLiteError(
      operation: operation,
      code: sqlite3_errcode(handle),
      message: messageWithPath(Self.errorMessage(handle)),
      sql: sql
    )
  }

  private func messageWithPath(_ message: String) -> String {
    guard let path, !message.contains(path) else {
      return message
    }
    return "\(path): \(message)"
  }

  private static func errorMessage(_ handle: OpaquePointer?) -> String {
    guard let message = sqlite3_errmsg(handle) else {
      return "unknown sqlite error"
    }
    return String(cString: message)
  }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
