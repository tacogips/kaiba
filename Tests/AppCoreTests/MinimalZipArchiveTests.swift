import Foundation
@testable import AppCore
import XCTest

#if canImport(Compression)
import Compression
#endif

final class MinimalZipArchiveTests: XCTestCase {
  func testReadsStoredAndDeflatedEntries() throws {
    let stored = Data("stored payload".utf8)
    let deflated = Data(String(repeating: "compress me ", count: 64).utf8)
    let archive = try MinimalZipArchive(data: try XCTUnwrap(TestZipBuilder.archive([
      TestZipBuilder.Input(path: "mimetype", contents: stored, deflate: false),
      TestZipBuilder.Input(path: "nested/body.xhtml", contents: deflated, deflate: true)
    ])))

    XCTAssertEqual(archive.entries.map(\.path), ["mimetype", "nested/body.xhtml"])
    XCTAssertEqual(archive.entry(forPath: "mimetype")?.compressionMethod, MinimalZipArchive.storedMethod)
    XCTAssertEqual(
      archive.entry(forPath: "nested/body.xhtml")?.compressionMethod,
      MinimalZipArchive.deflateMethod
    )
    XCTAssertEqual(try archive.data(forPath: "mimetype"), stored)
    XCTAssertEqual(try archive.data(forPath: "nested/body.xhtml"), deflated)
    XCTAssertTrue(archive.contains(path: "mimetype"))
    XCTAssertFalse(archive.contains(path: "missing.txt"))
  }

  func testReadsEmptyEntry() throws {
    let archive = try MinimalZipArchive(data: try XCTUnwrap(TestZipBuilder.archive([
      TestZipBuilder.Input(path: "empty.txt", contents: Data(), deflate: false)
    ])))
    XCTAssertEqual(try archive.data(forPath: "empty.txt"), Data())
  }

  func testFindsCentralDirectoryBehindAnArchiveComment() throws {
    let contents = Data("commented archive".utf8)
    let archive = try MinimalZipArchive(data: try XCTUnwrap(TestZipBuilder.archive(
      [TestZipBuilder.Input(path: "a.txt", contents: contents, deflate: false)],
      comment: "trailing comment bytes"
    )))
    XCTAssertEqual(try archive.data(forPath: "a.txt"), contents)
  }

  func testMissingEntryThrows() throws {
    let archive = try MinimalZipArchive(data: try XCTUnwrap(TestZipBuilder.archive([
      TestZipBuilder.Input(path: "a.txt", contents: Data("a".utf8), deflate: false)
    ])))
    XCTAssertThrowsError(try archive.data(forPath: "b.txt")) { error in
      XCTAssertEqual(error as? MinimalZipArchive.Failure, .entryNotFound("b.txt"))
    }
  }

  func testNonZipDataThrows() {
    XCTAssertThrowsError(try MinimalZipArchive(data: Data("not a zip archive at all".utf8))) { error in
      XCTAssertEqual(error as? MinimalZipArchive.Failure, .notAZipArchive)
    }
    XCTAssertThrowsError(try MinimalZipArchive(data: Data())) { error in
      XCTAssertEqual(error as? MinimalZipArchive.Failure, .notAZipArchive)
    }
  }

  func testReadsRealEPUBFixture() throws {
    let url = try fixtureURL(named: "sample.epub")
    let archive = try MinimalZipArchive(fileURL: url)

    XCTAssertEqual(archive.entries.count, 11)
    XCTAssertEqual(
      archive.entry(forPath: "mimetype")?.compressionMethod,
      MinimalZipArchive.storedMethod
    )
    XCTAssertEqual(
      archive.entry(forPath: "EPUB/content.opf")?.compressionMethod,
      MinimalZipArchive.deflateMethod
    )
    XCTAssertEqual(
      String(data: try archive.data(forPath: "mimetype"), encoding: .utf8),
      "application/epub+zip"
    )
    let opf = try XCTUnwrap(
      String(data: try archive.data(forPath: "EPUB/content.opf"), encoding: .utf8)
    )
    XCTAssertTrue(opf.contains("<spine toc=\"ncx\">"))
    XCTAssertEqual(
      try archive.data(forPath: "EPUB/media/file0.png").count,
      archive.entry(forPath: "EPUB/media/file0.png")?.uncompressedSize
    )
  }
}

/// Builds tiny ZIP archives in memory so the reader can be exercised without
/// checking binary fixtures into the repository.
enum TestZipBuilder {
  struct Input {
    var path: String
    var contents: Data
    var deflate: Bool
  }

  static func archive(_ inputs: [Input], comment: String = "") -> Data? {
    var payload = Data()
    var directory = Data()
    var offsets: [Int] = []
    for input in inputs {
      guard let stored = encode(input) else {
        return nil
      }
      offsets.append(payload.count)
      payload.append(localHeader(for: input, stored: stored))
      payload.append(stored.bytes)
    }
    for (index, input) in inputs.enumerated() {
      guard let stored = encode(input) else {
        return nil
      }
      directory.append(centralDirectoryEntry(
        for: input,
        stored: stored,
        localHeaderOffset: offsets[index]
      ))
    }

    var result = payload
    let directoryOffset = result.count
    result.append(directory)
    result.append(uint32(0x0605_4b50))
    result.append(uint16(0))
    result.append(uint16(0))
    result.append(uint16(UInt16(inputs.count)))
    result.append(uint16(UInt16(inputs.count)))
    result.append(uint32(UInt32(directory.count)))
    result.append(uint32(UInt32(directoryOffset)))
    let commentBytes = Data(comment.utf8)
    result.append(uint16(UInt16(commentBytes.count)))
    result.append(commentBytes)
    return result
  }

  private struct StoredPayload {
    var bytes: Data
    var method: UInt16
  }

  private static func encode(_ input: Input) -> StoredPayload? {
    guard input.deflate else {
      return StoredPayload(bytes: input.contents, method: 0)
    }
    guard let compressed = deflate(input.contents) else {
      return nil
    }
    return StoredPayload(bytes: compressed, method: 8)
  }

  private static func localHeader(for input: Input, stored: StoredPayload) -> Data {
    var header = Data()
    header.append(uint32(0x0403_4b50))
    header.append(uint16(20))
    header.append(uint16(0))
    header.append(uint16(stored.method))
    header.append(uint16(0))
    header.append(uint16(0))
    header.append(uint32(crc32(input.contents)))
    header.append(uint32(UInt32(stored.bytes.count)))
    header.append(uint32(UInt32(input.contents.count)))
    let name = Data(input.path.utf8)
    header.append(uint16(UInt16(name.count)))
    header.append(uint16(0))
    header.append(name)
    return header
  }

  private static func centralDirectoryEntry(
    for input: Input,
    stored: StoredPayload,
    localHeaderOffset: Int
  ) -> Data {
    var entry = Data()
    entry.append(uint32(0x0201_4b50))
    entry.append(uint16(20))
    entry.append(uint16(20))
    entry.append(uint16(0))
    entry.append(uint16(stored.method))
    entry.append(uint16(0))
    entry.append(uint16(0))
    entry.append(uint32(crc32(input.contents)))
    entry.append(uint32(UInt32(stored.bytes.count)))
    entry.append(uint32(UInt32(input.contents.count)))
    let name = Data(input.path.utf8)
    entry.append(uint16(UInt16(name.count)))
    entry.append(uint16(0))
    entry.append(uint16(0))
    entry.append(uint16(0))
    entry.append(uint16(0))
    entry.append(uint32(0))
    entry.append(uint32(UInt32(localHeaderOffset)))
    entry.append(name)
    return entry
  }

  private static func deflate(_ data: Data) -> Data? {
    #if canImport(Compression)
    let source = [UInt8](data)
    guard !source.isEmpty else {
      return Data()
    }
    var destination = [UInt8](repeating: 0, count: source.count * 2 + 128)
    let written = destination.withUnsafeMutableBufferPointer { output -> Int in
      source.withUnsafeBufferPointer { input -> Int in
        guard let outputBase = output.baseAddress, let inputBase = input.baseAddress else {
          return 0
        }
        return compression_encode_buffer(
          outputBase,
          output.count,
          inputBase,
          input.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard written > 0 else {
      return nil
    }
    return Data(destination[0..<written])
    #else
    return nil
    #endif
  }

  private static let crcTable: [UInt32] = (0..<256).map { index in
    (0..<8).reduce(UInt32(index)) { value, _ in
      (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
    }
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }

  private static func uint16(_ value: UInt16) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
  }

  private static func uint32(_ value: UInt32) -> Data {
    Data([
      UInt8(value & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 24) & 0xFF)
    ])
  }
}
