import Foundation
@testable import AppCore
import XCTest

final class GoogleDocumentAIPageRecognizerTests: XCTestCase {
  func testGatewayRequestAndCredentialIsolation() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(root, """
    #!/usr/bin/python3
    import sys, os, json, base64
    args = sys.argv[1:]
    assert args[:2] == ['writer', 'projects.locations.processors.process']
    assert args[args.index('--location')+1] == 'us'
    assert args[args.index('--param')+1] == 'name=projects/test/locations/us/processors/ocr'
    assert args[args.index('--service-account-env')+1] == 'GOOGLE_APPLICATION_CREDENTIALS_JSON'
    assert os.environ['GOOGLE_APPLICATION_CREDENTIALS_JSON'] == 'fake-secret'
    assert 'UNRELATED_SECRET' not in os.environ
    assert 'BASH_ENV' not in os.environ
    assert os.getcwd() == os.path.realpath(os.environ['HOME'])
    assert os.stat(os.environ['HOME']).st_mode & 0o777 == 0o700
    request = json.load(sys.stdin)
    assert request['fieldMask'] == 'text,error,pages.pageNumber'
    assert base64.b64decode(request['rawDocument']['content']) == b'page bytes'
    assert request['rawDocument']['mimeType'] == 'image/png'
    assert request['processOptions']['ocrConfig']['hints']['languageHints'] == ['ja']
    print(json.dumps({'ok':True,'data':{'document':{'text':'右の列。\\n左の列。','pages':[{}]}}}))
    """)
    let recognizer = GoogleDocumentAIPageRecognizer(
      configuration: .init(processorName: resource, commandPath: gateway.path, languageHints: ["ja"]),
      environment: ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "fake-secret", "UNRELATED_SECRET": "private", "BASH_ENV": "/never-source"]
    )
    XCTAssertEqual(try recognizer.recognize(imageURL: image(root)), "右の列。\n左の列。")
  }

  func testFactorySupportsVersionAndAccessTokenInServedMode() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(root, """
    #!/bin/sh
    [ "$2" = 'projects.locations.processors.processorVersions.process' ] || exit 10
    [ "$8" = '-' ] || exit 11
    [ "$9" = '--access-token-env' ] || exit 12
    shift 9
    [ "$1" = 'OCR_TOKEN' ] || exit 13
    [ "$OCR_TOKEN" = 'fake' ] || exit 14
    [ -z "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ] || exit 15
    /bin/cat >/dev/null
    printf '%s' '{"ok":true,"data":{"document":{"text":"recognized","pages":[{}]}}}'
    """)
    // Explicit engine remains authoritative when both providers are configured.
    let settings = KaibaImportConfiguration(
      ocr: .init(vendor: "codex", model: "unused"), ocrEngine: .googleDocumentAI,
      googleDocumentAI: .init(processorName: resource + "/processorVersions/test", commandPath: gateway.path, accessTokenEnvironmentVariable: "OCR_TOKEN")
    )
    let recognizer = try settings.makePageRecognizer(
      environment: ["OCR_TOKEN": "fake", "GOOGLE_APPLICATION_CREDENTIALS_JSON": "do-not-forward"], executionMode: .served
    )
    XCTAssertEqual(try recognizer.recognize(imageURL: image(root)), "recognized")
  }

  func testParserPreservesUnicodeAndBlankPagesButRejectsPartialResponses() throws {
    let text = "縦書き𠮷野家。\n二列目。\n"
    let data = try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["document": ["text": text, "pages": [[:]]]]])
    XCTAssertEqual(try GoogleDocumentAIPageRecognizer.parseResponse(data), text)
    XCTAssertEqual(try GoogleDocumentAIPageRecognizer.parseResponse(Data(#"{"ok":true,"data":{"document":{"pages":[{}]}}}"#.utf8)), "")
    for invalid in [
      #"{"ok":true,"data":{"document":{"text":"partial","error":{"code":13},"pages":[{}]}}}"#,
      "not json", #"{"ok":false,"data":{"document":{"text":"partial","pages":[{}]}}}"#,
      #"{"ok":true,"data":{"document":{"text":"partial"}}}"#,
      #"{"ok":true,"data":{"document":{"text":"partial","pages":[{"error":{"code":13}}]}}}"#
    ] {
      XCTAssertThrowsError(try GoogleDocumentAIPageRecognizer.parseResponse(Data(invalid.utf8)))
    }
  }

  func testConfigurationRoundTripAndPreflightRejectInvalidInputs() throws {
    let config = KaibaImportConfiguration(googleDocumentAI: .init(processorName: resource))
    XCTAssertEqual(config.resolvedOCREngine, .googleDocumentAI)
    XCTAssertEqual(try JSONDecoder().decode(KaibaImportConfiguration.self, from: JSONEncoder().encode(config)), config)
    XCTAssertThrowsError(try KaibaImportConfiguration(ocrEngine: .googleDocumentAI).makePageRecognizer())
    for name in ["", "processor", "projects/test/locations/us/processors/ocr/", resource + "/../bad"] {
      XCTAssertThrowsError(try GoogleDocumentAIPageRecognizer(configuration: .init(processorName: name)).recognize(imageURL: URL(fileURLWithPath: "/missing.png")))
    }
    for key in ["HOME", "PATH", "BASH_ENV", "DYLD_INSERT_LIBRARIES", "BAD-NAME", ""] {
      let recognizer = GoogleDocumentAIPageRecognizer(configuration: .init(processorName: resource, accessTokenEnvironmentVariable: key), environment: [key: "secret"])
      XCTAssertThrowsError(try recognizer.recognize(imageURL: URL(fileURLWithPath: "/missing.png")))
    }
  }

  func testErrorsDoNotExposeCredentialsOrPageContent() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(root, """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s' '{"error":{"httpStatus":403,"provider":{"details":[{"reason":"SERVICE_DISABLED"}],"message":"secret-page secret-key"}}}' >&2
    exit 4
    """)
    let recognizer = GoogleDocumentAIPageRecognizer(configuration: .init(processorName: resource, commandPath: gateway.path), environment: ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "secret-key"])
    XCTAssertThrowsError(try recognizer.recognize(imageURL: image(root))) { error in
      XCTAssertEqual(error as? DocumentConversionError, .failed("Google Document AI API is disabled for the configured Google Cloud project"))
    }
  }

  func testGatewayTimeoutIsBounded() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(root, "#!/bin/sh\n/bin/sleep 30\n")
    let recognizer = GoogleDocumentAIPageRecognizer(configuration: .init(processorName: resource, commandPath: gateway.path, timeoutSeconds: 1), environment: ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "fake"])
    let start = Date()
    XCTAssertThrowsError(try recognizer.recognize(imageURL: image(root)))
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
  }

  func testCLIImportAndDeferredOCRUseGoogleConfiguration() throws {
    let root = try fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try script(root, """
    #!/bin/sh
    /bin/cat >/dev/null
    printf '%s' '{"ok":true,"data":{"document":{"text":"日本語の本文。","pages":[{}]}}}'
    """)
    let settings = KaibaConfiguration(importSettings: .init(googleDocumentAI: .init(processorName: resource, commandPath: gateway.path)))
    let config = root.appendingPathComponent("config.json")
    try JSONEncoder().encode(settings).write(to: config)
    let base = ["--note-root", root.appendingPathComponent("store").path, "--config", config.path]
    let environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "fake"]
    let source = try image(root)
    _ = try AppCommand(arguments: base + ["import", source.path, "--max-ocr-pages", "0", "--ocr-engine", "google-document-ai"], environment: environment).run()
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.appendingPathComponent("store").path))
    let notebook = try XCTUnwrap(service.listNotebooks().first)
    let note = try XCTUnwrap(service.listNotes(notebookId: notebook.notebookId).first)
    XCTAssertEqual(try NoteService.importedPageMetadata(note).ocrState, "pending")
    _ = try AppCommand(arguments: base + ["page-ocr", note.noteId.rawValue], environment: environment).run()
    XCTAssertEqual(try service.getNote(note.noteId).bodyMarkdown, "日本語の本文。")
    let previousIds = Set(try service.listNotebooks().map(\.notebookId))
    _ = try AppCommand(arguments: base + ["import", source.path, "--max-ocr-pages", "1"], environment: environment).run()
    let added = try service.listNotebooks().filter { !previousIds.contains($0.notebookId) }
    XCTAssertEqual(added.count, 1)
    let imported = try XCTUnwrap(added.first)
    XCTAssertEqual(try service.listNotes(notebookId: imported.notebookId).first?.bodyMarkdown, "日本語の本文。")
  }

  private var resource: String { "projects/test/locations/us/processors/ocr" }

  private func fixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-ai-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func script(_ root: URL, _ body: String) throws -> URL {
    let url = root.appendingPathComponent("gateway")
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private func image(_ root: URL) throws -> URL {
    let url = root.appendingPathComponent("page.png")
    try Data("page bytes".utf8).write(to: url)
    return url
  }
}
