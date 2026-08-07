import Foundation
import AppCore
import XCTest

final class NoteFileReclamationTests: NoteTestCase {
  func testGCRemovesOrphanedRowAndBlobWhileReferencedFileSurvives() throws {
    let service = try makeService()
    let keptNote = try service.createNote(bodyMarkdown: "# Kept\nBody")
    let doomedNote = try service.createNote(bodyMarkdown: "# Doomed\nBody")

    let kept = try service.attachFile(noteId: keptNote.noteId, data: Data("keep".utf8), mediaType: "text/plain")
    let orphaned = try service.attachFile(noteId: doomedNote.noteId, data: Data("drop".utf8), mediaType: "text/plain")

    let filesRoot = filesRootURL(for: service)
    let orphanBlob = filesRoot.appendingPathComponent(try XCTUnwrap(orphaned.file.localPath))
    let keptBlob = filesRoot.appendingPathComponent(try XCTUnwrap(kept.file.localPath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: orphanBlob.path))

    // Deleting the note drops only the join row, leaving the `files` row orphaned.
    try service.deleteNote(noteId: doomedNote.noteId)

    let result = try service.reclaimUnreferencedFiles(olderThan: 0)

    XCTAssertEqual(result.deletedFileIds, [orphaned.file.fileId])
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBlob.path))
    XCTAssertThrowsError(try service.getFileRecord(fileId: orphaned.file.fileId))

    // The still-referenced file keeps its row and blob.
    XCTAssertTrue(FileManager.default.fileExists(atPath: keptBlob.path))
    XCTAssertEqual(try service.getFileRecord(fileId: kept.file.fileId).fileId, kept.file.fileId)
  }

  func testGCSweepsStrayBlobsAndTempFilesOlderThanGraceButKeepsYoungerOnes() throws {
    let service = try makeService()
    let filesRoot = filesRootURL(for: service)
    let shard = filesRoot.appendingPathComponent("ab", isDirectory: true)
    try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)

    let oldStrayBlob = shard.appendingPathComponent("file-old-orphan")
    let oldTempFile = shard.appendingPathComponent(".file-old.tmp-\(UUID().uuidString)")
    let youngStrayBlob = shard.appendingPathComponent("file-young-orphan")
    let youngTempFile = shard.appendingPathComponent(".file-young.tmp-\(UUID().uuidString)")
    for url in [oldStrayBlob, oldTempFile, youngStrayBlob, youngTempFile] {
      try Data("stray".utf8).write(to: url)
    }
    // Backdate the "old" entries well beyond the grace window.
    let oldDate = Date().addingTimeInterval(-48 * 60 * 60)
    for url in [oldStrayBlob, oldTempFile] {
      try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path)
    }

    let result = try service.reclaimUnreferencedFiles(olderThan: 24 * 60 * 60)

    XCTAssertFalse(FileManager.default.fileExists(atPath: oldStrayBlob.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldTempFile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: youngStrayBlob.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: youngTempFile.path))
    XCTAssertEqual(
      Set(result.sweptPaths),
      Set(["ab/\(oldStrayBlob.lastPathComponent)", "ab/\(oldTempFile.lastPathComponent)"])
    )
  }

  func testPostCommitDeleteFailureReportsMigratedWithCleanupWarningAndRerunSkips() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Migrate\nBody")
    let attachment = try service.attachFile(noteId: note.noteId, data: Data("move".utf8), mediaType: "text/plain")

    // Make the stored blob undeletable by removing write permission from its
    // parent shard directory, so removeItem throws (EPERM) after the commit.
    let filesRoot = filesRootURL(for: service)
    let blobURL = filesRoot.appendingPathComponent(try XCTUnwrap(attachment.file.localPath))
    let shardURL = blobURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shardURL.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shardURL.path)
    }

    let client = ReclamationS3Client()
    let result = try service.migrateAllLocalFiles(to: reclamationS3Profile(), httpClient: client)

    // The migration is durable (row is now S3) and reported migrated, with the
    // undeletable local path surfaced as a cleanup warning.
    XCTAssertEqual(result.migrated.map(\.fileId), [attachment.file.fileId])
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertEqual(result.cleanupFailures.map(\.fileId), [attachment.file.fileId])
    XCTAssertEqual(try service.getFileRecord(fileId: attachment.file.fileId).storageKind, .s3)

    // A rerun has nothing left to migrate (the row is already S3).
    let rerun = try service.migrateAllLocalFiles(to: reclamationS3Profile(), httpClient: client)
    XCTAssertTrue(rerun.migrated.isEmpty)
    XCTAssertTrue(rerun.cleanupFailures.isEmpty)
  }

  func testDBFailureAfterS3PutAttemptsS3DeleteAndLeavesRecordLocal() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Compensate\nBody")
    let attachment = try service.attachFile(noteId: note.noteId, data: Data("compensate".utf8), mediaType: "text/plain")

    // verifyRemoteRead runs a GET right after the PUT and before the DB update.
    // Failing that GET simulates a pre-commit failure after the object exists.
    let client = ReclamationS3Client(failGetPaths: ["/notes/riela/\(attachment.file.fileId)"])

    XCTAssertThrowsError(
      try service.migrateFileStorage(
        fileId: attachment.file.fileId,
        to: reclamationS3Profile(),
        httpClient: client,
        verifyRemoteRead: true
      )
    )

    // The just-uploaded object was compensated (deleted) and the record stays local.
    XCTAssertEqual(try service.getFileRecord(fileId: attachment.file.fileId).storageKind, .local)
    XCTAssertTrue(client.methods.contains("DELETE"), "expected a compensating S3 DELETE, saw \(client.methods)")
  }

  private func filesRootURL(for service: NoteService) -> URL {
    URL(fileURLWithPath: service.driver.databasePath)
      .deletingLastPathComponent()
      .appendingPathComponent("files", isDirectory: true)
  }
}

private func reclamationS3Profile() -> S3StorageProfile {
  S3StorageProfile(
    name: "reclaim-s3",
    endpoint: URL(string: "https://s3.example.test")!,
    region: "ap-northeast-1",
    bucket: "notes",
    accessKeyId: "access-key",
    secretAccessKey: "secret-key",
    keyPrefix: "riela"
  )
}

private final class ReclamationS3Client: S3HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private var recordedMethods: [String] = []
  private let failGetPaths: Set<String>

  init(failGetPaths: Set<String> = []) {
    self.failGetPaths = failGetPaths
  }

  var methods: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMethods
  }

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    lock.lock()
    defer { lock.unlock() }
    recordedMethods.append(request.method)
    switch request.method {
    case "PUT":
      objects[request.url.path] = request.body
      return S3HTTPResponse(statusCode: 200)
    case "GET":
      if failGetPaths.contains(request.url.path) {
        return S3HTTPResponse(statusCode: 500)
      }
      guard let data = objects[request.url.path] else {
        return S3HTTPResponse(statusCode: 404)
      }
      return S3HTTPResponse(statusCode: 200, body: data)
    case "DELETE":
      objects.removeValue(forKey: request.url.path)
      return S3HTTPResponse(statusCode: 204)
    default:
      return S3HTTPResponse(statusCode: 400)
    }
  }
}
