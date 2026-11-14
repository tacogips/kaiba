#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct LocalNoteFileStore: NoteFileStore {
  public var noteRoot: String

  public init(noteRoot: String) {
    self.noteRoot = noteRoot
  }

  public func store(data: Data, fileId: FileID) throws -> StoredNoteFile {
    let relativePath = localPath(for: fileId)
    let destination = filesRoot().appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(fileId).tmp-\(UUID().uuidString)")
    try data.write(to: temporary, options: [.atomic])
    defer {
      if FileManager.default.fileExists(atPath: temporary.path) {
        try? FileManager.default.removeItem(at: temporary)
      }
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(
        destination,
        withItemAt: temporary,
        backupItemName: nil,
        options: []
      )
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }

    return StoredNoteFile(
      locator: NoteFileLocator(storageKind: .local, localPath: relativePath),
      byteSize: Int64(data.count),
      sha256: sha256Hex(data)
    )
  }

  public func store(fileURL: URL, fileId: FileID) throws -> StoredNoteFile {
    let relativePath = localPath(for: fileId)
    let destination = filesRoot().appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(fileId).tmp-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: fileURL, to: temporary)
    defer {
      if FileManager.default.fileExists(atPath: temporary.path) {
        try? FileManager.default.removeItem(at: temporary)
      }
    }
    let checksum = try sha256Hex(fileURL: temporary)
    let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
    let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(
        destination,
        withItemAt: temporary,
        backupItemName: nil,
        options: []
      )
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }

    return StoredNoteFile(
      locator: NoteFileLocator(storageKind: .local, localPath: relativePath),
      byteSize: byteSize,
      sha256: checksum
    )
  }

  public func read(record: FileRecord) throws -> Data {
    let data = try Data(contentsOf: fileURL(record: record))
    let actual = sha256Hex(data)
    guard actual == record.sha256 else {
      throw NoteFileStoreError.checksumMismatch(expected: record.sha256, actual: actual)
    }
    return data
  }

  public func delete(record: FileRecord) throws {
    let url = try fileURL(record: record)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  public func fileURL(record: FileRecord) throws -> URL {
    guard record.storageKind == .local else {
      throw NoteFileStoreError.unsupportedStorageKind(record.storageKind)
    }
    guard let localPath = record.localPath else {
      throw NoteFileStoreError.missingLocalPath(record.fileId)
    }
    return filesRoot().appendingPathComponent(localPath).standardizedFileURL
  }

  private func filesRoot() -> URL {
    URL(fileURLWithPath: noteRoot, isDirectory: true).appendingPathComponent("files", isDirectory: true)
  }

  private func localPath(for fileId: FileID) -> String {
    let shard = SHA256.hash(data: Data(fileId.rawValue.utf8))
      .prefix(1)
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(shard)/\(fileId)"
  }
}

func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(fileURL: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: fileURL)
  defer {
    try? handle.close()
  }
  var hasher = SHA256()
  while true {
    let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
    if chunk.isEmpty {
      break
    }
    hasher.update(data: chunk)
  }
  return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
