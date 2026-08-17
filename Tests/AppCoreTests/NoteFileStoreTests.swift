import Foundation
import Network
import AppCore
import XCTest

final class NoteFileStoreTests: NoteTestCase {
  func testAttachResolveAndListNoteFile() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# With File\nBody")
    let data = Data("hello attachment".utf8)

    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: data,
      role: .embedded,
      mediaType: "text/plain",
      originalFilename: "hello.txt",
      position: 7
    )

    XCTAssertEqual(attachment.role, .embedded)
    XCTAssertEqual(attachment.position, 7)
    XCTAssertEqual(attachment.file.storageKind, .local)
    XCTAssertEqual(attachment.file.byteSize, Int64(data.count))
    XCTAssertEqual(attachment.file.originalFilename, "hello.txt")
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), data)
    XCTAssertEqual(try service.listFiles(noteId: note.noteId), [attachment])
  }

  func testAttachNoteFileDirectlyToS3WithoutMigration() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Direct S3\nBody")
    let data = Data("direct s3 attachment".utf8)
    let client = InMemoryS3HTTPClient()

    let attachment = try service.attachFile(
      noteId: note.noteId,
      data: data,
      mediaType: "text/plain",
      originalFilename: "direct.txt",
      s3Profile: testS3Profile(),
      httpClient: client
    )

    XCTAssertEqual(attachment.file.storageKind, .s3)
    XCTAssertNil(attachment.file.localPath)
    XCTAssertEqual(attachment.file.s3Profile, "test-s3")
    XCTAssertEqual(try client.object(path: "/notes/riela/\(attachment.file.fileId)"), data)
    XCTAssertEqual(try service.listFiles(noteId: note.noteId), [attachment])
    XCTAssertEqual(
      try service.resolveFileContent(fileId: attachment.file.fileId, s3Profiles: [testS3Profile()], httpClient: client),
      data
    )
    XCTAssertEqual(client.requests().map(\.method), ["PUT", "GET"])
  }

  func testListNoteFilesOrdersByPositionWithinRole() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Ordered Files\nBody")
    let last = try service.attachFile(
      noteId: note.noteId,
      data: Data("last".utf8),
      role: .related,
      mediaType: "text/plain",
      originalFilename: "last.txt",
      position: 20
    )
    let first = try service.attachFile(
      noteId: note.noteId,
      data: Data("first".utf8),
      role: .related,
      mediaType: "text/plain",
      originalFilename: "first.txt",
      position: 10
    )

    XCTAssertEqual(try service.listFiles(noteId: note.noteId).map(\.file.fileId), [
      first.file.fileId,
      last.file.fileId
    ])
  }

  func testNotebookSourceDocumentAttachment() throws {
    let service = try makeService()
    let notebook = try service.createNotebook(
      title: "Imported",
      kindTagName: "notebook-kind:imported-material"
    )
    let data = Data("source pdf bytes".utf8)

    let attachment = try service.attachNotebookFile(
      notebookId: notebook.notebookId,
      data: data,
      role: .sourceDocument,
      mediaType: "application/pdf",
      originalFilename: "source.pdf"
    )

    XCTAssertEqual(attachment.role, .sourceDocument)
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), data)
    XCTAssertEqual(try service.listFiles(notebookId: notebook.notebookId), [attachment])
  }

  func testAttachFileRejectsMissingNoteWithoutWritingBlob() throws {
    let root = try makeNoteRoot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))

    XCTAssertThrowsError(try service.attachFile(
      noteId: NoteID("missing-note"),
      data: Data("orphan".utf8),
      mediaType: "text/plain"
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("note not found: missing-note"))
    }

    let filesRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("files", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: filesRoot.path))
  }

  func testAttachNotebookFileRejectsMissingNotebookWithoutWritingBlob() throws {
    let root = try makeNoteRoot()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root))

    XCTAssertThrowsError(try service.attachNotebookFile(
      notebookId: NotebookID("missing-notebook"),
      data: Data("orphan".utf8),
      mediaType: "text/plain"
    )) { error in
      XCTAssertEqual(error as? NoteServiceError, .notFound("notebook not found: missing-notebook"))
    }

    let filesRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("files", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: filesRoot.path))
  }

  func testFileRecordAndContentSurviveNoteDeletion() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Disposable\nBody")
    let data = Data("kept bytes".utf8)
    let attachment = try service.attachFile(noteId: note.noteId, data: data, mediaType: "text/plain")

    try service.deleteNote(noteId: note.noteId)

    XCTAssertEqual(try service.getFileRecord(fileId: attachment.file.fileId), attachment.file)
    XCTAssertEqual(try service.resolveFileContent(fileId: attachment.file.fileId), data)
  }

  func testLocalFileStoreDetectsChecksumMismatch() throws {
    let root = try makeNoteRoot()
    let store = LocalNoteFileStore(noteRoot: root)
    let data = Data("expected".utf8)
    let stored = try store.store(data: data, fileId: FileID("file-checksum"))
    let record = FileRecord(
      fileId: FileID("file-checksum"),
      storageKind: .local,
      localPath: stored.locator.localPath,
      s3Profile: nil,
      s3Bucket: nil,
      s3Key: nil,
      mediaType: "text/plain",
      byteSize: stored.byteSize,
      sha256: "not-the-real-hash",
      originalFilename: nil,
      createdAt: "2026-07-04T00:00:00Z",
      migratedAt: nil
    )

    XCTAssertThrowsError(try store.read(record: record)) { error in
      XCTAssertEqual(
        error as? NoteFileStoreError,
        .checksumMismatch(expected: "not-the-real-hash", actual: stored.sha256)
      )
    }
  }

  func testLocalFileStoreShardsByFileIdHashInsteadOfGeneratedPrefix() throws {
    let root = try makeNoteRoot()
    let store = LocalNoteFileStore(noteRoot: root)

    let stored = try store.store(data: Data("sharded".utf8), fileId: FileID("file-hash-shard"))

    XCTAssertEqual(stored.locator.localPath, "b0/file-hash-shard")
    XCTAssertNotEqual(stored.locator.localPath, "fi/file-hash-shard")
  }

  func testLocalFileStoreReplacesExistingBlobWithoutLeavingTemporaryFiles() throws {
    let root = try makeNoteRoot()
    let store = LocalNoteFileStore(noteRoot: root)
    let fileId = FileID("file-replace")
    let first = try store.store(data: Data("first".utf8), fileId: fileId)
    let secondData = Data("second".utf8)

    let second = try store.store(data: secondData, fileId: fileId)

    XCTAssertNotEqual(first.sha256, second.sha256)
    let fileURL = URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(try XCTUnwrap(second.locator.localPath))
    XCTAssertEqual(try Data(contentsOf: fileURL), secondData)
    let remainingTemporaryFiles = try FileManager.default.contentsOfDirectory(
      atPath: fileURL.deletingLastPathComponent().path
    ).filter { $0.hasPrefix(".\(fileId.rawValue).tmp-") }
    XCTAssertEqual(remainingTemporaryFiles, [])
  }

  func testMigrateFileStorageCopiesSwitchesLocatorAndDeletesLocalFileWithoutDoubleTransfer() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Migrated\nBody")
    let data = Data("move me".utf8)
    let attachment = try service.attachFile(noteId: note.noteId, data: data, mediaType: "text/plain")
    let originalLocalPath = try XCTUnwrap(attachment.file.localPath)
    let noteRoot = URL(fileURLWithPath: service.driver.databasePath).deletingLastPathComponent()
    let originalFileURL = noteRoot.appendingPathComponent("files").appendingPathComponent(originalLocalPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalFileURL.path))

    let client = InMemoryS3HTTPClient()
    let migrated = try service.migrateFileStorage(
      fileId: attachment.file.fileId,
      to: testS3Profile(),
      httpClient: client
    )

    XCTAssertEqual(migrated.storageKind, .s3)
    XCTAssertNil(migrated.localPath)
    XCTAssertEqual(migrated.s3Profile, "test-s3")
    XCTAssertEqual(migrated.s3Bucket, "notes")
    XCTAssertEqual(migrated.s3Key, "riela/\(attachment.file.fileId)")
    XCTAssertEqual(try client.object(path: "/notes/riela/\(attachment.file.fileId)"), data)
    XCTAssertEqual(try service.listFiles(noteId: note.noteId).first?.file.storageKind, .s3)
    XCTAssertEqual(
      try service.resolveFileContent(fileId: attachment.file.fileId, s3Profiles: [testS3Profile()], httpClient: client),
      data
    )
    XCTAssertThrowsError(try service.resolveFileContent(fileId: attachment.file.fileId)) { error in
      XCTAssertEqual(error as? NoteFileStoreError, .unsupportedStorageKind(.s3))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: originalFileURL.path))

    let requests = client.requests()
    XCTAssertEqual(requests.map(\.method), ["PUT", "GET"])
    XCTAssertEqual(requests.first?.headers["x-amz-content-sha256"], attachment.file.sha256)
    XCTAssertTrue(requests.first?.headers["authorization"]?.contains("AWS4-HMAC-SHA256") == true)
  }

  func testMigrateFileStorageCanVerifyRemoteReadWhenRequested() throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Verified Migration\nBody")
    let attachment = try service.attachFile(noteId: note.noteId, data: Data("verify me".utf8), mediaType: "text/plain")
    let client = InMemoryS3HTTPClient()

    _ = try service.migrateFileStorage(
      fileId: attachment.file.fileId,
      to: testS3Profile(),
      httpClient: client,
      verifyRemoteRead: true
    )

    XCTAssertEqual(client.requests().map(\.method), ["PUT", "GET"])
  }

  func testBulkMigrationContinuesPastPerFileFailure() throws {
    let service = try makeService()
    let first = try service.createNote(bodyMarkdown: "# First\nBody")
    let second = try service.createNote(bodyMarkdown: "# Second\nBody")
    let firstFile = try service.attachFile(noteId: first.noteId, data: Data("ok".utf8), mediaType: "text/plain")
    let secondFile = try service.attachFile(noteId: second.noteId, data: Data("fail".utf8), mediaType: "text/plain")
    let client = InMemoryS3HTTPClient(failingPutPaths: ["/notes/riela/\(secondFile.file.fileId)"])

    let result = try service.migrateAllLocalFiles(to: testS3Profile(), httpClient: client)

    XCTAssertEqual(result.migrated.map(\.fileId), [firstFile.file.fileId])
    XCTAssertEqual(result.failures.map(\.fileId), [secondFile.file.fileId])
    XCTAssertEqual(try service.getFileRecord(fileId: firstFile.file.fileId).storageKind, .s3)
    XCTAssertEqual(try service.getFileRecord(fileId: secondFile.file.fileId).storageKind, .local)
  }

  func testS3StoreUsesURLSessionAgainstStubHTTPServer() throws {
    let server = try StubS3HTTPServer()
    defer {
      server.stop()
    }
    let profile = S3StorageProfile(
      name: "stub-s3",
      endpoint: server.endpoint,
      region: "ap-northeast-1",
      bucket: "notes",
      accessKeyId: "access-key",
      secretAccessKey: "secret-key",
      keyPrefix: "http"
    )
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# HTTP S3\nBody")
    let attachment = try service.attachFile(noteId: note.noteId, data: Data("over http".utf8), mediaType: "text/plain")

    let migrated = try service.migrateFileStorage(fileId: attachment.file.fileId, to: profile)

    XCTAssertEqual(migrated.storageKind, .s3)
    XCTAssertEqual(migrated.s3Key, "http/\(attachment.file.fileId)")
    XCTAssertEqual(try server.object(path: "/notes/http/\(attachment.file.fileId)"), Data("over http".utf8))
    XCTAssertEqual(
      try service.resolveFileContent(fileId: attachment.file.fileId, s3Profiles: [profile]),
      Data("over http".utf8)
    )
    let requests = server.requests()
    XCTAssertEqual(requests.map(\.method), ["PUT", "GET"])
    XCTAssertTrue(requests.allSatisfy { $0.headers["authorization"]?.contains("AWS4-HMAC-SHA256") == true })
  }

  func testS3StorePercentEncodesKeyForSigV4RequestPath() throws {
    let server = try StubS3HTTPServer()
    defer {
      server.stop()
    }
    let profile = S3StorageProfile(
      name: "stub-s3",
      endpoint: server.endpoint,
      region: "ap-northeast-1",
      bucket: "notes",
      accessKeyId: "access-key",
      secretAccessKey: "secret-key",
      keyPrefix: "riela"
    )
    let store = S3NoteFileStore(profile: profile, now: fixedS3Date)
    let fileId = FileID("file space+日本語")
    let data = Data("encoded key".utf8)

    let stored = try store.store(data: data, fileId: fileId)
    let record = FileRecord(
      fileId: fileId,
      storageKind: .s3,
      localPath: nil,
      s3Profile: stored.locator.s3Profile,
      s3Bucket: stored.locator.s3Bucket,
      s3Key: stored.locator.s3Key,
      mediaType: "text/plain",
      byteSize: stored.byteSize,
      sha256: stored.sha256,
      originalFilename: nil,
      createdAt: "2026-07-04T00:00:00Z",
      migratedAt: nil
    )

    XCTAssertEqual(try store.read(record: record), data)
    let expectedPath = "/notes/riela/file%20space%2B%E6%97%A5%E6%9C%AC%E8%AA%9E"
    let requests = server.requests()
    XCTAssertEqual(requests.map(\.path), [expectedPath, expectedPath])
    XCTAssertTrue(requests.allSatisfy { request in
      request.headers["authorization"]?.contains("AWS4-HMAC-SHA256") == true
        && request.headers["authorization"]?.contains("SignedHeaders=") == true
    })
  }
}

private func testS3Profile() -> S3StorageProfile {
  S3StorageProfile(
    name: "test-s3",
    endpoint: URL(string: "https://s3.example.test")!,
    region: "ap-northeast-1",
    bucket: "notes",
    accessKeyId: "access-key",
    secretAccessKey: "secret-key",
    keyPrefix: "riela"
  )
}

private func fixedS3Date() -> Date {
  Date(timeIntervalSince1970: 1_783_107_200)
}

private final class InMemoryS3HTTPClient: S3HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private var recordedRequests: [S3HTTPRequest] = []
  private var failingPutPaths: Set<String>

  init(failingPutPaths: Set<String> = []) {
    self.failingPutPaths = failingPutPaths
  }

  func send(_ request: S3HTTPRequest) throws -> S3HTTPResponse {
    lock.lock()
    defer { lock.unlock() }
    recordedRequests.append(request)
    switch request.method {
    case "PUT":
      if failingPutPaths.contains(request.url.path) {
        return S3HTTPResponse(statusCode: 503, body: Data("unavailable".utf8))
      }
      objects[request.url.path] = request.body
      return S3HTTPResponse(statusCode: 200)
    case "GET":
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

  func object(path: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    return try XCTUnwrap(objects[path])
  }

  func requests() -> [S3HTTPRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }
}

private final class StubS3HTTPServer: @unchecked Sendable {
  struct Request: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  private(set) var endpoint: URL
  private let listener: NWListener
  private let queue = DispatchQueue(label: "StubS3HTTPServer")
  private let lock = NSLock()
  private var objects: [String: Data] = [:]
  private var recordedRequests: [Request] = []

  init() throws {
    let listener = try NWListener(using: .tcp, on: 0)
    self.listener = listener
    endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
    let ready = DispatchSemaphore(value: 0)
    let readyState = StubS3HTTPServerReadyState()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        readyState.store(port: listener.port, error: nil)
        ready.signal()
      case let .failed(error):
        readyState.store(port: nil, error: error)
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    ready.wait()
    let result = readyState.result()
    if let readyError = result.error {
      throw readyError
    }
    guard let readyPort = result.port else {
      throw NSError(domain: "StubS3HTTPServer", code: 1)
    }
    endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(readyPort.rawValue)"))
  }

  func stop() {
    listener.cancel()
  }

  func object(path: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    return try XCTUnwrap(objects[path])
  }

  func requests() -> [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, accumulated: Data())
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var buffer = accumulated
      if let data {
        buffer.append(data)
      }
      if let request = parseRequest(buffer) {
        respond(to: request, on: connection)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        receive(on: connection, accumulated: buffer)
      }
    }
  }

  private func respond(to request: Request, on connection: NWConnection) {
    let response: (status: Int, body: Data)
    lock.lock()
    recordedRequests.append(request)
    switch request.method {
    case "PUT":
      objects[request.path] = request.body
      response = (200, Data())
    case "GET":
      if let body = objects[request.path] {
        response = (200, body)
      } else {
        response = (404, Data())
      }
    case "DELETE":
      objects.removeValue(forKey: request.path)
      response = (204, Data())
    default:
      response = (405, Data())
    }
    lock.unlock()

    let head = """
    HTTP/1.1 \(response.status) OK\r
    Content-Length: \(response.body.count)\r
    Connection: close\r
    \r

    """
    var payload = Data(head.utf8)
    payload.append(response.body)
    connection.send(content: payload, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func parseRequest(_ data: Data) -> Request? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      return nil
    }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else {
      return nil
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else {
        continue
      }
      let name = line[..<separator].lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      headers[String(name)] = value
    }
    let bodyStart = headerEnd.upperBound
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else {
      return nil
    }
    let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
    return Request(
      method: String(requestParts[0]),
      path: String(requestParts[1]),
      headers: headers,
      body: data[bodyStart..<bodyEnd]
    )
  }
}

private final class StubS3HTTPServerReadyState: @unchecked Sendable {
  private let lock = NSLock()
  private var portValue: NWEndpoint.Port?
  private var errorValue: Error?

  func store(port: NWEndpoint.Port?, error: Error?) {
    lock.lock()
    portValue = port
    errorValue = error
    lock.unlock()
  }

  func result() -> (port: NWEndpoint.Port?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (portValue, errorValue)
  }
}
