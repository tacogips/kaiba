import Foundation
import Testing

@testable import AppCore

private func makeTempRoot(function: String = #function) throws -> String {
  let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("AppCoreTests-config-path", isDirectory: true)
    .appendingPathComponent("\(function)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.path
}

@Test func sqliteDatabasePathDecodesAndRoundTrips() throws {
  let json = #"{"database":{"kind":"sqlite","path":"/custom/kaiba/store.sqlite"}}"#
  let decoded = try JSONDecoder().decode(KaibaConfiguration.self, from: Data(json.utf8))
  #expect(decoded.database == .sqlite(path: "/custom/kaiba/store.sqlite"))

  let reencoded = try JSONDecoder().decode(
    KaibaConfiguration.self,
    from: try JSONEncoder().encode(decoded)
  )
  #expect(reencoded.database == .sqlite(path: "/custom/kaiba/store.sqlite"))

  let bare = try JSONDecoder().decode(
    KaibaConfiguration.self,
    from: Data(#"{"database":{"kind":"sqlite"}}"#.utf8)
  )
  #expect(bare.database == .sqlite(path: nil))
}

@Test func sqliteDatabasePathResolutionPrecedence() {
  #expect(
    KaibaConfigurationLoader.resolveSQLiteDatabasePath(
      configuredPath: "/config/store.sqlite",
      noteRoot: "/root",
      environment: ["KAIBA_SQLITE_PATH": "/env/store.sqlite"]
    ) == "/env/store.sqlite"
  )
  #expect(
    KaibaConfigurationLoader.resolveSQLiteDatabasePath(
      configuredPath: "/config/store.sqlite",
      noteRoot: "/root",
      environment: [:]
    ) == "/config/store.sqlite"
  )
  #expect(
    KaibaConfigurationLoader.resolveSQLiteDatabasePath(
      configuredPath: nil,
      noteRoot: "/root",
      environment: [:]
    ) == "/root/note-store.sqlite"
  )
  #expect(
    KaibaConfigurationLoader.resolveSQLiteDatabasePath(
      configuredPath: "~/kaiba-store.sqlite",
      noteRoot: "/root",
      environment: [:]
    ) == (NSHomeDirectory() as NSString).appendingPathComponent("kaiba-store.sqlite")
  )
  // An empty env value must not shadow the configured path.
  #expect(
    KaibaConfigurationLoader.resolveSQLiteDatabasePath(
      configuredPath: "/config/store.sqlite",
      noteRoot: "/root",
      environment: ["KAIBA_SQLITE_PATH": ""]
    ) == "/config/store.sqlite"
  )
}

@Test func makeDriverUsesConfiguredSQLitePathAndCreatesParentDirectory() throws {
  let root = try makeTempRoot()
  let custom = "\(root)/nested/dir/custom-store.sqlite"
  let driver = try KaibaConfigurationLoader.makeDriver(
    configuration: .sqlite(path: custom),
    noteRoot: "\(root)/unused-note-root",
    environment: [:]
  )
  #expect(driver.databasePath == custom)
  var isDirectory: ObjCBool = false
  #expect(FileManager.default.fileExists(
    atPath: "\(root)/nested/dir",
    isDirectory: &isDirectory
  ))
  #expect(isDirectory.boolValue)

  // The database must actually land at the custom path once used.
  let service = try NoteService(driver: driver)
  _ = try service.createNote(bodyMarkdown: "custom path note")
  #expect(FileManager.default.fileExists(atPath: custom))
  #expect(!FileManager.default.fileExists(atPath: "\(root)/unused-note-root/note-store.sqlite"))
}

@Test func makeDriverEnvironmentOverridesConfiguredSQLitePath() throws {
  let root = try makeTempRoot()
  let configured = "\(root)/configured.sqlite"
  let overridden = "\(root)/env-override.sqlite"
  let driver = try KaibaConfigurationLoader.makeDriver(
    configuration: .sqlite(path: configured),
    noteRoot: root,
    environment: ["KAIBA_SQLITE_PATH": overridden]
  )
  #expect(driver.databasePath == overridden)
}

@Test func cliEndToEndWritesSQLiteToConfiguredPath() throws {
  let root = try makeTempRoot()
  let noteRoot = "\(root)/notes"
  let customStore = "\(root)/data/store.sqlite"
  let configPath = "\(root)/config.json"
  let config = #"{"database":{"kind":"sqlite","path":"\#(customStore)"}}"#
  try Data(config.utf8).write(to: URL(fileURLWithPath: configPath))

  let created = try AppCommand(
    arguments: [
      "--note-root", noteRoot, "--config", configPath,
      "add", "--body", "# stored in custom sqlite", "--output", "json"
    ],
    environment: [:]
  ).run()
  #expect(created.contains("noteId"))
  #expect(FileManager.default.fileExists(atPath: customStore))
  #expect(!FileManager.default.fileExists(atPath: "\(noteRoot)/note-store.sqlite"))

  // The same note must be readable back through search over the custom store.
  let searched = try AppCommand(
    arguments: [
      "--note-root", noteRoot, "--config", configPath,
      "search", "custom sqlite", "--output", "json"
    ],
    environment: [:]
  ).run()
  #expect(searched.contains("stored in custom sqlite"))
}

@Test func makeS3ProfilesRejectsMissingCredentialEnvironment() throws {
  let configuration = KaibaConfiguration(storageProfiles: [KaibaS3ProfileConfiguration(
    name: "gateway",
    endpoint: "http://127.0.0.1:8443",
    region: "us-east-1",
    bucket: "kaiba-files",
    accessKeyIdEnvironmentVariable: "KAIBA_S3_ACCESS",
    secretAccessKeyEnvironmentVariable: "KAIBA_S3_SECRET"
  )])
  #expect(throws: NoteFileStoreError.missingEnvironmentValue("KAIBA_S3_ACCESS")) {
    _ = try KaibaConfigurationLoader.makeS3Profiles(
      configuration: configuration,
      environment: ["KAIBA_S3_SECRET": "secret"]
    )
  }
  #expect(throws: NoteFileStoreError.missingEnvironmentValue("KAIBA_S3_SECRET")) {
    _ = try KaibaConfigurationLoader.makeS3Profiles(
      configuration: configuration,
      environment: ["KAIBA_S3_ACCESS": "client"]
    )
  }
}

@Test func makeS3ProfilesRejectsEndpointWithoutScheme() throws {
  let configuration = KaibaConfiguration(storageProfiles: [KaibaS3ProfileConfiguration(
    name: "gateway",
    endpoint: "127.0.0.1:8443",
    region: "us-east-1",
    bucket: "kaiba-files",
    accessKeyIdEnvironmentVariable: "KAIBA_S3_ACCESS",
    secretAccessKeyEnvironmentVariable: "KAIBA_S3_SECRET"
  )])
  #expect(throws: KaibaConfigurationError.invalid("storageProfiles.gateway.endpoint")) {
    _ = try KaibaConfigurationLoader.makeS3Profiles(
      configuration: configuration,
      environment: ["KAIBA_S3_ACCESS": "client", "KAIBA_S3_SECRET": "secret"]
    )
  }
}
