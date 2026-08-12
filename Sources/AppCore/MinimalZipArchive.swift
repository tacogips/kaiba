import Foundation

#if canImport(Compression)
import Compression
#endif

/// Read-only ZIP reader covering exactly what EPUB containers need: a plain
/// (non-ZIP64, unencrypted) central directory with stored and deflated entries.
/// Kept in-tree so document import does not pull in an archive dependency.
public struct MinimalZipArchive: Sendable {
  public enum Failure: Swift.Error, Equatable {
    case notAZipArchive
    case corruptArchive(String)
    case entryNotFound(String)
    case unsupportedCompressionMethod(UInt16)
    case decompressionUnavailable
    case decompressionFailed(String)
  }

  public struct Entry: Equatable, Sendable {
    public var path: String
    public var compressionMethod: UInt16
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var localHeaderOffset: Int
  }

  public static let storedMethod: UInt16 = 0
  public static let deflateMethod: UInt16 = 8
  /// Largest entry this reader will materialize, guarding against zip bombs.
  public static let maximumEntryBytes = 256 * 1024 * 1024

  private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
  private static let centralDirectorySignature: UInt32 = 0x0201_4b50
  private static let localHeaderSignature: UInt32 = 0x0403_4b50
  /// End-of-central-directory record plus the largest possible zip comment.
  private static let maximumEndRecordSearch = 22 + 0xFFFF

  public let entries: [Entry]
  private let bytes: [UInt8]
  private let entryIndexByPath: [String: Int]

  public init(data: Data) throws {
    let bytes = [UInt8](data)
    let entries = try Self.readCentralDirectory(bytes: bytes)
    self.bytes = bytes
    self.entries = entries
    var index: [String: Int] = [:]
    for (position, entry) in entries.enumerated() where index[entry.path] == nil {
      index[entry.path] = position
    }
    self.entryIndexByPath = index
  }

  public init(fileURL: URL) throws {
    try self.init(data: try Data(contentsOf: fileURL, options: [.mappedIfSafe]))
  }

  public func contains(path: String) -> Bool {
    entryIndexByPath[path] != nil
  }

  public func entry(forPath path: String) -> Entry? {
    entryIndexByPath[path].map { entries[$0] }
  }

  public func data(forPath path: String) throws -> Data {
    guard let position = entryIndexByPath[path] else {
      throw Failure.entryNotFound(path)
    }
    return try data(for: entries[position])
  }

  public func data(for entry: Entry) throws -> Data {
    guard entry.uncompressedSize <= Self.maximumEntryBytes else {
      throw Failure.corruptArchive("entry is larger than the supported maximum: \(entry.path)")
    }
    let signature = try uint32(at: entry.localHeaderOffset)
    guard signature == Self.localHeaderSignature else {
      throw Failure.corruptArchive("missing local header for \(entry.path)")
    }
    let nameLength = Int(try uint16(at: entry.localHeaderOffset + 26))
    let extraLength = Int(try uint16(at: entry.localHeaderOffset + 28))
    let start = entry.localHeaderOffset + 30 + nameLength + extraLength
    let end = start + entry.compressedSize
    guard start >= 0, end >= start, end <= bytes.count else {
      throw Failure.corruptArchive("entry payload is out of bounds: \(entry.path)")
    }
    let payload = Array(bytes[start..<end])
    switch entry.compressionMethod {
    case Self.storedMethod:
      return Data(payload)
    case Self.deflateMethod:
      return try Self.inflate(payload, uncompressedSize: entry.uncompressedSize, path: entry.path)
    default:
      throw Failure.unsupportedCompressionMethod(entry.compressionMethod)
    }
  }

  // MARK: - Central directory

  private static func readCentralDirectory(bytes: [UInt8]) throws -> [Entry] {
    guard bytes.count >= 22 else {
      throw Failure.notAZipArchive
    }
    guard let endRecord = endOfCentralDirectoryOffset(bytes: bytes) else {
      throw Failure.notAZipArchive
    }
    let entryCount = Int(try uint16(in: bytes, at: endRecord + 10))
    let directorySize = Int(try uint32(in: bytes, at: endRecord + 12))
    let directoryOffset = Int(try uint32(in: bytes, at: endRecord + 16))
    guard directoryOffset >= 0,
          directorySize >= 0,
          directoryOffset + directorySize <= bytes.count else {
      throw Failure.corruptArchive("central directory is out of bounds")
    }

    var entries: [Entry] = []
    entries.reserveCapacity(entryCount)
    var cursor = directoryOffset
    while entries.count < entryCount, cursor + 46 <= directoryOffset + directorySize {
      guard try uint32(in: bytes, at: cursor) == centralDirectorySignature else {
        throw Failure.corruptArchive("unexpected central directory signature")
      }
      let method = try uint16(in: bytes, at: cursor + 10)
      let compressedSize = Int(try uint32(in: bytes, at: cursor + 20))
      let uncompressedSize = Int(try uint32(in: bytes, at: cursor + 24))
      let nameLength = Int(try uint16(in: bytes, at: cursor + 28))
      let extraLength = Int(try uint16(in: bytes, at: cursor + 30))
      let commentLength = Int(try uint16(in: bytes, at: cursor + 32))
      let localHeaderOffset = Int(try uint32(in: bytes, at: cursor + 42))
      let nameStart = cursor + 46
      let nameEnd = nameStart + nameLength
      guard nameEnd <= bytes.count else {
        throw Failure.corruptArchive("entry name is out of bounds")
      }
      guard compressedSize != Int(UInt32.max), uncompressedSize != Int(UInt32.max) else {
        throw Failure.corruptArchive("ZIP64 archives are not supported")
      }
      // Names are UTF-8 in every modern writer; the Latin-1 fallback keeps a
      // legacy CP437 name addressable instead of dropping the entry.
      let nameBytes = Data(bytes[nameStart..<nameEnd])
      let name = String(data: nameBytes, encoding: .utf8)
        ?? String(data: nameBytes, encoding: .isoLatin1)
        ?? ""
      // Directory markers carry no payload worth reading.
      if !name.hasSuffix("/") {
        entries.append(Entry(
          path: name,
          compressionMethod: method,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset
        ))
      }
      cursor = nameEnd + extraLength + commentLength
    }
    return entries
  }

  /// Scans backwards for the end-of-central-directory signature, which may sit
  /// behind a trailing archive comment.
  private static func endOfCentralDirectoryOffset(bytes: [UInt8]) -> Int? {
    let lowerBound = max(0, bytes.count - maximumEndRecordSearch)
    var offset = bytes.count - 22
    while offset >= lowerBound {
      if (try? uint32(in: bytes, at: offset)) == endOfCentralDirectorySignature {
        let commentLength = Int((try? uint16(in: bytes, at: offset + 20)) ?? 0)
        if offset + 22 + commentLength == bytes.count {
          return offset
        }
      }
      offset -= 1
    }
    return nil
  }

  // MARK: - Deflate

  private static func inflate(
    _ payload: [UInt8],
    uncompressedSize: Int,
    path: String
  ) throws -> Data {
    guard uncompressedSize > 0 else {
      return Data()
    }
    #if canImport(Compression)
    // The central directory records the exact decoded size, so a buffer one
    // byte larger both fits the payload and detects an overlong stream.
    var destination = [UInt8](repeating: 0, count: uncompressedSize + 1)
    let written = destination.withUnsafeMutableBufferPointer { output -> Int in
      payload.withUnsafeBufferPointer { input -> Int in
        guard let outputBase = output.baseAddress, let inputBase = input.baseAddress else {
          return 0
        }
        return compression_decode_buffer(
          outputBase,
          output.count,
          inputBase,
          input.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard written == uncompressedSize else {
      throw Failure.decompressionFailed(path)
    }
    return Data(destination[0..<written])
    #else
    throw Failure.decompressionUnavailable
    #endif
  }

  // MARK: - Little-endian reads

  private func uint16(at offset: Int) throws -> UInt16 {
    try Self.uint16(in: bytes, at: offset)
  }

  private func uint32(at offset: Int) throws -> UInt32 {
    try Self.uint32(in: bytes, at: offset)
  }

  private static func uint16(in bytes: [UInt8], at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else {
      throw Failure.corruptArchive("read past the end of the archive")
    }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func uint32(in bytes: [UInt8], at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else {
      throw Failure.corruptArchive("read past the end of the archive")
    }
    return UInt32(bytes[offset])
      | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }
}
