import Foundation
import XCTest
@testable import AppCore

final class SearchEngineSettingsTests: NoteTestCase {
  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  func testResolverHonorsConfigThenStoreThenNoneAndBindsSecretToTarget() async throws {
    let service = try makeService(function: #function)
    let none = try service.resolveSearchEngineSettings(configuration: nil, environment: [:])
    if case .none = none {} else { XCTFail("expected none") }

    let input = SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700/", authMode: "apiKey",
      secret: "secret-value"
    )
    _ = try await service.updateSearchEngineSettings(input)
    let stored = try service.resolveSearchEngineSettings(configuration: nil, environment: [:])
    if case let .store(settings, secret) = stored {
      XCTAssertEqual(settings.url, "https://search.internal:7700/")
      XCTAssertEqual(secret, "secret-value")
    } else {
      XCTFail("expected store settings")
    }

    let config = KaibaSearchEngineConfiguration(kind: "meilisearch", enabled: false, url: "https://config.internal")
    let managed = try service.resolveSearchEngineSettings(configuration: config, environment: [:])
    if case .managedByConfig(let resolved) = managed {
      XCTAssertEqual(resolved, config)
    } else {
      XCTFail("config must take precedence")
    }

    try service.setAppSetting(
      key: NoteService.searchEngineSecretKey,
      valueJSON: #"{"authMode":"apiKey","target":"https://attacker.example","secret":"secret-value"}"#,
      allowReserved: true
    )
    let mismatched = try service.resolveSearchEngineSettings(configuration: nil, environment: [:])
    if case .store(_, let secret) = mismatched {
      XCTAssertNil(secret)
    } else {
      XCTFail("expected store settings")
    }
  }

  func testUpdateRetargetRequiresNewSecretAndTestMakesNoEngineCall() async throws {
    let service = try makeService(function: #function)
    let original = SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700", authMode: "apiKey",
      secret: "secret-value"
    )
    let view = try await service.updateSearchEngineSettings(original)
    XCTAssertTrue(view.hasSecret)
    XCTAssertFalse(String(describing: view).contains("secret-value"))
    let before = try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true)

    let retarget = SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://attacker.example", authMode: "apiKey"
    )
    do {
      _ = try await service.updateSearchEngineSettings(retarget)
      XCTFail("retarget should require a new secret")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.secret"))
    }
    XCTAssertEqual(try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true), before)

    var factoryCalls = 0
    let result = try await service.testSearchEngineConnection(retarget) { _, _ in
      factoryCalls += 1
      return FakeSearchEngine()
    }
    XCTAssertEqual(result.status, .invalidSettings)
    XCTAssertEqual(result.detail, "searchEngine.secret")
    XCTAssertEqual(factoryCalls, 0)
  }

  func testNormalizedTargetRetainsSecretAndAuthModeChangeDoesNot() async throws {
    let service = try makeService(function: #function)
    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700/", authMode: "apiKey",
      secret: "secret-value"
    ))
    let sameTarget = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700", authMode: "apiKey"
    ))
    XCTAssertTrue(sameTarget.hasSecret)

    // A secret stored for another auth mode on the same target is not reused.
    try service.setAppSetting(
      key: NoteService.searchEngineSecretKey,
      valueJSON: #"{"authMode":"basic","target":"https://search.internal:7700","secret":"secret-value"}"#,
      allowReserved: true
    )
    let changedAuth = SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700", authMode: "apiKey"
    )
    let result = try await service.testSearchEngineConnection(changedAuth) { _, _ in FakeSearchEngine() }
    XCTAssertEqual(result.detail, "searchEngine.secret")
    XCTAssertEqual(result.status, .invalidSettings)
  }

  func testTestConnectionRedactsAndTruncatesDetailAndUpdateReloadsOnce() async throws {
    let slot = SearchEngineSlot()
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)
    let reloadCount = LockedCounter()
    slot.setReloadHandler {
      reloadCount.increment()
      return SearchEngineReloadOutcome(active: true, indexIdentity: "test")
    }
    let input = SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal", authMode: "apiKey",
      secret: "secret-value"
    )
    _ = try await service.updateSearchEngineSettings(input)
    XCTAssertEqual(reloadCount.count, 1)

    let fake = FakeSearchEngine()
    fake.failure = .unavailable("boom secret-value " + String(repeating: "x", count: 300))
    let result = try await service.testSearchEngineConnection(input) { settings, secret in
      _ = try SearchEngineFactory.make(settings: settings, secret: secret)
      return fake
    }
    XCTAssertEqual(fake.healthCalls, 1)
    XCTAssertEqual(result.status, .unavailable)
    XCTAssertFalse(result.detail.contains("secret-value"))
    XCTAssertLessThanOrEqual(result.detail.count, 200)

    do {
      _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
        kind: "meilisearch", url: "https://search.internal", authMode: "apiKey", clearSecret: true
      ))
      XCTFail("clearSecret with API key auth should fail")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.secret"))
    }
    XCTAssertEqual(reloadCount.count, 1)
  }

  func testDisableDeletesSecretAndGenericSettingsCannotReachReservedKeys() async throws {
    let service = try makeService(function: #function)
    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal", authMode: "apiKey",
      secret: "secret-value"
    ))
    let view = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "none"))
    XCTAssertEqual(view.kind, "none")
    XCTAssertNil(try service.appSetting(key: NoteService.searchEngineSecretKey, allowReserved: true))
    XCTAssertThrowsError(try service.appSetting(key: NoteService.searchEngineSecretKey))
    XCTAssertThrowsError(try service.setAppSetting(key: NoteService.searchEngineSettingsKey, valueJSON: #"{"kind":"none"}"#))
  }

  func testConfigManagedViewIsReadOnly() async throws {
    let slot = SearchEngineSlot()
    slot.setManagedConfiguration(KaibaSearchEngineConfiguration(
      kind: "meilisearch", url: "https://config.internal", apiKeyEnvironmentVariable: "SEARCH_API_KEY"
    ))
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)
    let view = try service.searchEngineSettings()
    XCTAssertEqual(view.managedBy, .config)
    XCTAssertEqual(view.authMode, .apiKey)
    XCTAssertTrue(view.hasSecret)
    do {
      _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "none"))
      XCTFail("config settings should be locked")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .managedByConfig)
    }
    do {
      _ = try await service.testSearchEngineConnection(SearchEngineSettingsInput(kind: "none"))
      XCTFail("config settings should be locked")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .managedByConfig)
    }
  }

  func testConfigManagedViewReturnsOnlyExplicitURL() throws {
    let slot = SearchEngineSlot()
    slot.setEnvironment(["KAIBA_MEILISEARCH_URL": "https://environment-only.example"])
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)

    slot.setManagedConfiguration(KaibaSearchEngineConfiguration(kind: "meilisearch"))
    XCTAssertNil(try service.searchEngineSettings().url)

    slot.setManagedConfiguration(KaibaSearchEngineConfiguration(
      kind: "meilisearch", url: "https://config.internal"
    ))
    XCTAssertEqual(try service.searchEngineSettings().url, "https://config.internal")
  }

  func testServerDefaultSavesWithoutURLAndReadsOnlyExplicitURL() async throws {
    let slot = SearchEngineSlot()
    let environment = ["KAIBA_MEILISEARCH_URL": "https://a.example"]
    slot.setEnvironment(environment)
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)

    for inputURL in [nil, "", "  "] as [String?] {
      let view = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
        kind: "meilisearch", url: inputURL, authMode: "none"
      ))
      let raw = try XCTUnwrap(service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
      let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      XCTAssertNil(row["url"])
      XCTAssertEqual(view.kind, "meilisearch")
      XCTAssertNil(view.url)
      XCTAssertNil(try service.searchEngineSettings().url)
    }

    let engine = try XCTUnwrap(service.makeResolvedSearchEngine(configuration: nil, environment: environment))
    XCTAssertEqual(engine.indexIdentity, "meilisearch:https://a.example/kaiba-notes-v1")

    let explicit = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", url: "https://search.internal:7700/", authMode: "none"
    ))
    XCTAssertEqual(explicit.url, "https://search.internal:7700/")
    let explicitRaw = try XCTUnwrap(service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
    let explicitRow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(explicitRaw.utf8)) as? [String: Any])
    XCTAssertEqual(explicitRow["url"] as? String, "https://search.internal:7700/")
  }

  func testLegacyBlankStoredURLResolvesFromEnvironmentButViewStaysNull() throws {
    let slot = SearchEngineSlot()
    let environment = ["KAIBA_MEILISEARCH_URL": "https://legacy-default.example"]
    slot.setEnvironment(environment)
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)

    for legacyURL in ["", "   "] {
      try service.setAppSetting(
        key: NoteService.searchEngineSettingsKey,
        valueJSON: "{\"kind\":\"meilisearch\",\"url\":\"\(legacyURL)\"}",
        allowReserved: true
      )
      let resolution = try service.resolveSearchEngineSettings(configuration: nil, environment: environment)
      if case .store(let settings, _) = resolution {
        XCTAssertEqual(settings.url, "https://legacy-default.example")
      } else {
        XCTFail("expected stored settings")
      }
      XCTAssertNil(try service.storedSearchEngineExplicitURL())
      XCTAssertNil(try service.searchEngineSettings().url)
    }
  }

  func testServerDefaultIdentityBackfillsAndSecretFailsClosedAfterEnvironmentRetarget() async throws {
    let slot = SearchEngineSlot()
    let environmentA = ["KAIBA_MEILISEARCH_URL": "https://a.example"]
    let environmentB = ["KAIBA_MEILISEARCH_URL": "https://b.example"]
    slot.setEnvironment(environmentA)
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)
    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "meilisearch", authMode: "none"))

    let engineA = try XCTUnwrap(service.makeResolvedSearchEngine(configuration: nil, environment: environmentA))
    let engineB = try XCTUnwrap(service.makeResolvedSearchEngine(configuration: nil, environment: environmentB))
    XCTAssertTrue(engineA.indexIdentity.contains("a.example"))
    XCTAssertTrue(engineB.indexIdentity.contains("b.example"))
    XCTAssertTrue(try service.activateSearchEngineSync(indexIdentity: engineA.indexIdentity))
    XCTAssertTrue(try service.activateSearchEngineSync(indexIdentity: engineB.indexIdentity))

    _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
      kind: "meilisearch", authMode: "apiKey", secret: "key-a"
    ))
    let resolutionA = try service.resolveSearchEngineSettings(configuration: nil, environment: environmentA)
    if case .store(_, let secret) = resolutionA {
      XCTAssertEqual(secret, "key-a")
    } else {
      XCTFail("expected stored settings")
    }
    let resolutionB = try service.resolveSearchEngineSettings(configuration: nil, environment: environmentB)
    if case .store(_, let secret) = resolutionB {
      XCTAssertNil(secret)
    } else {
      XCTFail("expected stored settings")
    }
    XCTAssertThrowsError(try service.makeResolvedSearchEngine(configuration: nil, environment: environmentB)) { error in
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.secret"))
    }

    slot.setEnvironment(environmentB)
    XCTAssertFalse(try service.searchEngineSettings().hasSecret)
  }

  func testServerDefaultTestConnectionUsesResolvedURLAndInvalidEnvironmentFailsClosed() async throws {
    let slot = SearchEngineSlot()
    let service = try NoteService(driver: try makeNoteDriver(function: #function), searchEngineSlot: slot)
    slot.setEnvironment(["KAIBA_MEILISEARCH_URL": "https://test-default.example"])
    var resolvedURL: String?
    let result = try await service.testSearchEngineConnection(SearchEngineSettingsInput(
      kind: "meilisearch", authMode: "none"
    )) { settings, _ in
      resolvedURL = settings.url
      return FakeSearchEngine()
    }
    XCTAssertEqual(resolvedURL, "https://test-default.example")
    XCTAssertFalse(result.detail.contains("test-default.example"))

    slot.setEnvironment(["KAIBA_MEILISEARCH_URL": "http://remote.example"])
    do {
      _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "meilisearch", authMode: "none"))
      XCTFail("remote plain HTTP environment must be rejected")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.url"))
    }
    XCTAssertNil(try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
    let invalid = try await service.testSearchEngineConnection(SearchEngineSettingsInput(kind: "meilisearch", authMode: "none"))
    XCTAssertEqual(invalid.status, .invalidSettings)
    XCTAssertEqual(invalid.detail, "searchEngine.url")
    XCTAssertNil(try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
  }

  func testInvalidStoredSettingMapsToFieldOnlyAndFactoryValidatesInputs() throws {
    let service = try makeService(function: #function)
    try service.setAppSetting(
      key: NoteService.searchEngineSettingsKey,
      valueJSON: #"{"kind":"meilisearch","url":"not a url"}"#,
      allowReserved: true
    )
    XCTAssertThrowsError(try service.makeResolvedSearchEngine(configuration: nil, environment: [:])) { error in
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.url"))
      XCTAssertFalse(String(describing: error).contains("not a url"))
    }
  }

  func testTestConnectionReportsEveryInvalidFieldWithoutPersisting() async throws {
    let service = try makeService(function: #function)
    let cases: [(SearchEngineSettingsInput, String)] = [
      (SearchEngineSettingsInput(kind: "unknown", url: "https://search.internal"), "searchEngine.kind"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "https://search.internal", authMode: "token"), "searchEngine.authMode"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "bad target"), "searchEngine.url"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "https://search.internal", indexPrefix: "Bad Prefix"), "searchEngine.indexPrefix"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "https://search.internal", authMode: "basic", username: "user", secret: "s"), "searchEngine.authMode"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "https://search.internal", authMode: "apiKey"), "searchEngine.secret"),
      (SearchEngineSettingsInput(kind: "meilisearch", url: "http://127.0.0.1:7700", verifyTLS: false), "searchEngine.verifyTLS")
    ]
    var factoryCalls = 0
    for (input, field) in cases {
      let result = try await service.testSearchEngineConnection(input) { settings, secret in
        _ = try SearchEngineFactory.make(settings: settings, secret: secret)
        factoryCalls += 1
        return FakeSearchEngine()
      }
      XCTAssertEqual(result.status, .invalidSettings)
      XCTAssertEqual(result.detail, field)
      XCTAssertLessThanOrEqual(result.detail.count, 200)
      XCTAssertNil(try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
    }
    XCTAssertEqual(factoryCalls, 0)
    do {
      _ = try await service.updateSearchEngineSettings(SearchEngineSettingsInput(
        kind: "meilisearch", url: "https://search.internal", requestTimeoutSeconds: 121
      ))
      XCTFail("update must reject a timeout above the configured range")
    } catch {
      XCTAssertEqual(error as? SearchEngineSettingsError, .invalid(field: "searchEngine.requestTimeoutSeconds"))
    }
    XCTAssertNil(try service.appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true))
  }

  func testSettingsReadUpdateAndTestAreAdminGated() async throws {
    let service = try makeService(function: #function)
    let user = try service.createUser(email: "search-settings@example.com", displayName: "Member")
    let member = service.scoped(to: user.userId)
    XCTAssertThrowsError(try member.searchEngineSettings()) { error in
      XCTAssertTrue(String(describing: error).contains("control-plane resource not found"))
    }
    do {
      _ = try await member.updateSearchEngineSettings(SearchEngineSettingsInput(kind: "none"))
      XCTFail("member update must be denied")
    } catch {
      XCTAssertTrue(String(describing: error).contains("control-plane resource not found"))
    }
    do {
      _ = try await member.testSearchEngineConnection(SearchEngineSettingsInput(kind: "none")) { _, _ in
        XCTFail("factory must not run before authorization")
        return FakeSearchEngine()
      }
      XCTFail("member test must be denied")
    } catch {
      XCTAssertTrue(String(describing: error).contains("control-plane resource not found"))
    }
  }

  private func makeService(function: String, slot: SearchEngineSlot = SearchEngineSlot()) throws -> NoteService {
    try NoteService(driver: makeNoteDriver(function: function), searchEngineSlot: slot)
  }

}
