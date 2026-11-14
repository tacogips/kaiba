import Foundation

public protocol NoteDatabaseDriving: Sendable {
  var databasePath: String { get }

  /// Runs work on a cached connection. A thrown body invalidates that exact
  /// handle; a later call must open and configure a new connection.
  func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T
}

public struct SQLiteNoteDatabaseDriver: NoteDatabaseDriving {
  public let databasePath: String
  public let openOptions: SQLiteOpenOptions
  private let connection: SQLiteNoteDatabaseConnection

  public init(
    noteRoot: String,
    openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)
  ) {
    databasePath = Self.defaultDatabasePath(noteRoot: noteRoot)
    self.openOptions = openOptions
    connection = SQLiteNoteDatabaseConnection(databasePath: databasePath, openOptions: openOptions)
  }

  public init(databasePath: String, openOptions: SQLiteOpenOptions = SQLiteOpenOptions(requireFTS5: true)) {
    self.databasePath = databasePath
    self.openOptions = openOptions
    connection = SQLiteNoteDatabaseConnection(databasePath: databasePath, openOptions: openOptions)
  }

  public static func defaultDatabasePath(noteRoot: String) -> String {
    URL(fileURLWithPath: noteRoot, isDirectory: true)
      .appendingPathComponent("note-store.sqlite")
      .path
  }

  public func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    try connection.withDatabase(body)
  }
}

/// A lazily-opened, lock-guarded cached SQLite connection.
///
/// The database is opened (and its FTS5/JSONB probes run) exactly once on first
/// use; every subsequent `withDatabase` call reuses the same handle under the
/// lock, so callers are serialized and a single configure/probe cycle occurs per
/// connection. Shared by `SQLiteNoteDatabaseDriver` and `LibSQLNoteDatabaseDriver`'s
/// `.local` mode.
public final class SQLiteNoteDatabaseConnection: @unchecked Sendable {
  private let databasePath: String
  private let openOptions: SQLiteOpenOptions
  private let lock = NSLock()
  private var database: SQLiteDatabase?

  public init(databasePath: String, openOptions: SQLiteOpenOptions) {
    self.databasePath = databasePath
    self.openOptions = openOptions
  }

  public func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
    lock.lock()
    defer {
      lock.unlock()
    }
    let database = try database ?? SQLiteDatabase.open(path: databasePath, options: openOptions)
    self.database = database
    do {
      return try body(database)
    } catch {
      // Never return a handle that may have failed while transaction or
      // connection-level PRAGMA state was changing to the reusable slot.
      self.database = nil
      throw error
    }
  }
}
