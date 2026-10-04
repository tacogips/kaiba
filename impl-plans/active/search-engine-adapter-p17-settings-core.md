# P17 Engine settings core: resolver, admin settings API, secret binding, CLI resolution

**Status**: Ready
**planId**: P17-settings-core
**Wave**: 3
**dependsOn**: P12-delta-contract, P13-es-adapter-delta, P7-cli
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D5 "Sources and precedence", "Store format", "Normalized connection settings and factory" and "AppCore API"; D0 (CLI uses the resolver); `design-docs/user-qa/search-engine-adapter.md` delta decisions "Config precedence", "Secret storage", "Secret binding to target" and "Administrator gate"
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

Administrators choose and configure the engine in the store, but only while the config file does not manage it. The settings API is admin-gated. The secret is write-only and bound to its auth mode and its normalized target URL. A test connection runs against unsaved settings with sanitized output. The CLI and the server resolve the effective engine with one shared resolver.

This plan is AppCore only. P18 exposes it over GraphQL, and P19 installs the slot reload handler in the server.

Repository facts:

- **Settings storage.** `Sources/AppCore/NoteService+AppSettings.swift`:
  - table `app_settings(setting_key, value_json jsonb, updated_at)`;
  - `reservedSettingKeyPrefix = "auth."`;
  - `normalizedSettingKey(_:allowReserved:)`;
  - the public `appSetting` and `setAppSetting` refuse reserved keys with the generic "invalid key" error.
- **Single-transaction write to imitate.** `NoteService+AuthTokens.swift` `authTokenSigningSecret()`: `driver.withDatabase { database in try database.transaction { db in ... INSERT INTO app_settings ... } }`.
- **Admin gate.** `requireStoreAdministrator(in:)` (`NoteService+Users.swift:239`), used by `NoteService+APIClients.swift:23`.
- **Write-only credential example.** `NoteService+UserAgentCredentials.swift`, a stored credential that is never returned.
- **P12.** `SearchEngineSettingsTypes.swift` defines the view, input, error, test-result and management types. `SearchEngineSlot` holds `managedConfiguration`, `environment` and `reload()`.
- **P13.** `SearchEngineFactory.make(settings:secret:)`, `SearchEngineFactory.adapters` and `SearchEngineFactory.normalizedTarget(_:)`. The factory throws `KaibaConfigurationError.invalid(field)`.
- **P7.** `Sources/AppCore/CommandSearchEngine.swift` builds the engine with `SearchEngineFactory.make(configuration:environment:)`.

## Non-goals

- No GraphQL, server or web change.
- No environment-variable credentials in store settings.
- No masked or partial secret in any read.
- No encryption-at-rest scheme beyond the existing store, matching the JWT secret precedent.
- No change to `appSetting`, `setAppSetting` or the reserved-prefix logic.

## writePaths

- `Sources/AppCore/SearchEngineSettingsResolver.swift` (new)
- `Sources/AppCore/NoteService+SearchEngineSettings.swift` (new)
- `Sources/AppCore/CommandSearchEngine.swift`
- `Tests/AppCoreTests/SearchEngineSettingsTests.swift` (new)
- `Tests/AppCoreTests/SearchEngineCommandTests.swift`
- `impl-plans/active/search-engine-adapter-p17-settings-core.md`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngineSettingsTypes.swift`: read-only. The P12 types.
- `Sources/AppCore/SearchEngineSlot.swift`: read-only. The P12 slot.
- `Sources/AppCore/SearchEngineFactory.swift`: read-only. P13's `make(settings:secret:)`, `adapters` and `normalizedTarget`.
- `Sources/AppCore/NoteService+AppSettings.swift`: read-only. The reserved prefix and key normalization.
- `Sources/AppCore/NoteService+AuthTokens.swift`: read-only. The single-transaction `app_settings` write pattern.
- `Sources/AppCore/NoteService+APIClients.swift`: read-only. The admin gate usage pattern.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only. `failure` and `healthCalls`.

## File-level changes

### `SearchEngineSettingsResolver.swift` (new)

**Resolution type.** `public enum SearchEngineSettingsResolution: Sendable` with three cases:

- `case managedByConfig(KaibaSearchEngineConfiguration)`
- `case store(SearchEngineConnectionSettings, secret: String?)`
- `case none`

**Storage keys.** Internal constants:

- `searchEngineSettingsKey = "auth.search-engine.settings"`
- `searchEngineSecretKey = "auth.search-engine.secret"`

**Stored shapes.** Internal `Codable` types:

- `StoredSearchEngineSettings { kind: String; url: String?; indexPrefix: String?; authMode: String?; username: String?; verifyTLS: Bool?; requestTimeoutSeconds: Int? }`
- `StoredSearchEngineSecret { authMode: String; target: String; secret: String }`

**`public extension NoteService`.** These methods have no admin gate. They are for the server process and the CLI, which already passed `requireStoreAdministrator()`.

- **`func resolveSearchEngineSettings(configuration: KaibaSearchEngineConfiguration?) throws -> SearchEngineSettingsResolution`.**
  - A non-nil config section, enabled or not, gives `.managedByConfig`.
  - Otherwise read both keys with `appSetting(key:allowReserved: true)`.
  - Absent settings, or `kind == "none"`, give `.none`.
  - Otherwise give `.store(settings mapped with the P12 defaults, secret)`.
  - The secret is used only when its `authMode` and `target` match the settings. A mismatch gives `secret: nil`, so the factory reports `searchEngine.secret`.
  - Undecodable stored JSON throws `SearchEngineSettingsError.invalid(field: "searchEngine.settings")`.
- **`func makeResolvedSearchEngine(configuration: KaibaSearchEngineConfiguration?, environment: [String: String]) throws -> (any SearchEngine)?`.**
  - The config case calls `SearchEngineFactory.make(configuration:environment:)` and propagates `KaibaConfigurationError`, which is fatal for callers.
  - The store case calls `make(settings:secret:)` and maps `KaibaConfigurationError.invalid(f)` to `SearchEngineSettingsError.invalid(field: f)`.
  - The none case returns nil.

### `NoteService+SearchEngineSettings.swift` (new)

Every public method first runs `try driver.withDatabase { try requireStoreAdministrator(in: $0) }`. Managed mode is `searchEngineSlot.managedConfiguration != nil`.

**`func searchEngineSettings() throws -> SearchEngineSettingsView`.**

- **Config view.**
  - `kind` is `config.isEnabled ? config.kind : "none"`.
  - `url` and the resolved prefix come from the section.
  - `authMode` is `apiKey` when `apiKeyEnvironmentVariable` is set, `basic` when the username and password variables are set, and `none` otherwise.
  - `username` is nil.
  - `hasSecret` is `authMode != .none`.
  - `verifyTLS` is true, and the timeout is 10.
- **Store view.** It comes from the stored settings. `hasSecret` is true only when a secret row exists, its `authMode` is not none, and it matches the settings' `authMode`.
- **Unset view.** `kind "none"` with the defaults.
- **Every view.** `adapters` is `SearchEngineFactory.adapters`, and `active` is `searchEngineSlot.engine != nil`.

**`func updateSearchEngineSettings(_ input: SearchEngineSettingsInput) async throws -> SearchEngineSettingsView`.** It forwards to an internal overload with a `makeEngine` closure, which defaults to `SearchEngineFactory.make(settings:secret:)`.

1. Managed mode throws `SearchEngineSettingsError.managedByConfig`.
2. `kind == "none"`: in one transaction, store `{"kind":"none"}` and delete the secret row. Then reload and return the view.
3. `kind` must be in `adapters`, otherwise `invalid("searchEngine.kind")`.
4. `authMode` must parse to `SearchEngineAuthMode`, otherwise `invalid("searchEngine.authMode")`. The default is `none`.
5. `target = SearchEngineFactory.normalizedTarget(url ?? "")`, otherwise `invalid("searchEngine.url")`.
6. **Effective secret:**
   - `authMode == .none` gives nil. The secret row will be deleted.
   - A non-empty `input.secret` is used as given.
   - `clearSecret == true` gives `invalid("searchEngine.secret")`.
   - Otherwise the stored secret is reused only when its `authMode` equals the new `authMode` and its `target` equals `target`. Any other case gives `invalid("searchEngine.secret")`.
7. Build the settings, applying the P12 defaults, and validate them by calling `makeEngine(settings, effectiveSecret)`. Map `KaibaConfigurationError.invalid(f)` to `.invalid(field: f)`. Nothing is persisted on failure.
8. In one `database.transaction`, upsert the settings JSON, then either upsert `{authMode, target, secret}` or delete the secret row.
9. `_ = await searchEngineSlot.reload()`, then return `searchEngineSettings()`.

**`func testSearchEngineConnection(_ input: SearchEngineSettingsInput) async throws -> SearchEngineConnectionTestResult`.** It has an internal overload with `makeEngine`.

- Managed mode throws `.managedByConfig`.
- Apply the same steps 3-7 to resolve and validate. Any `invalid(field:)` returns `SearchEngineConnectionTestResult(available: false, status: .invalidSettings, detail: field)` without calling `makeEngine`'s engine. `health()` must not be called, so there is no network request.
- Set `requestTimeoutSeconds = min(value, 10)` before building.
- Call `health()` and map the result:
  - `isAvailable` gives `.available`, with the detail set to the health detail.
  - Not available gives `.unhealthy`.
  - `SearchEngineError.unavailable(d)` gives `.unavailable`.
  - `.rejected(s, r)` gives `.rejected`, with the detail `"HTTP \(s) \(r)"`.
  - `.invalidResponse` gives `.invalidResponse`.
  - Any other error gives `.unavailable` with the detail `"transport failure"`.
- **Redaction.** Replace every occurrence of the effective secret and the username, when non-empty, with `[redacted]`. Then truncate to 200 characters.
- Persist nothing, and never call `ensureIndex`.

### `CommandSearchEngine.swift` (P7's file)

- Replace the direct `SearchEngineFactory.make(configuration:environment:)` call with `try service.makeResolvedSearchEngine(configuration:environment:)`.
- If P7 builds the engine before opening the service, reorder the code: open the service, check `requireStoreAdministrator()`, then resolve.
- Map `SearchEngineSettingsError.invalid(field:)` to exit 2 with the message `invalid search engine settings: <field>`. Never print a value.
- `status` prints `kind` from the resolved source.
- Keep every other behavior and exit code.

## Pitfalls

- **Secret never leaves.** It never appears in:
  - any returned view;
  - any error;
  - any `description`;
  - any log line, including `print` and `FileHandle.standardError.write`;
  - test failure messages. Compare booleans, not strings, that contain secrets.
- **Ordering in the secret retention rule.** The target comparison uses `normalizedTarget` on both sides. Reuse is refused when `authMode` or `target` differs.
- **Atomicity.** The settings write and the secret write or delete share one transaction.
- **Admin gate first.** No information, not even `managedBy`, is returned before the gate.
- **The reserved prefix already protects the keys.** Do not add new reserved-prefix code; add a test that proves it.
- **Swift 6 concurrency.** The `makeEngine` closure is `@Sendable`, or the call stays non-escaping.

## Tests (`SearchEngineSettingsTests`, XCTest)

**Gate and lock:**

- An acting non-admin user -> each of the three methods throws the not-found-shaped admin error.
- The unscoped local operator -> allowed.
- `slot.setManagedConfiguration(section)` -> `searchEngineSettings().managedBy == .config`, the view is derived from the section, and update and test both throw `.managedByConfig`.

**Validation:**

- Each invalid field (kind, authMode, url, indexPrefix, username, secret, timeout and verifyTLS on http) -> `invalid(field:)` with the exact field string, and `appSetting(key:allowReserved: true)` shows nothing persisted.

**Secret rules:**

- Save basic `https://es.internal:9200` with secret S -> the view has `hasSecret == true`, and no field equals S.
- Change the url to `https://attacker.example` and omit the secret:
  - update -> `invalid("searchEngine.secret")`, and the stored settings are unchanged;
  - test -> status `invalid-settings`, detail `searchEngine.secret`, and the injected engine factory is never called, or the fake's `healthCalls == 0`.
- Same url with only a trailing slash changed, and the secret omitted -> the stored secret is reused, so this is accepted.
- `authMode` changed from basic to apiKey, with the secret omitted -> rejected for both update and test.
- `clearSecret` together with basic -> invalid.
- `kind "none"` -> the secret row is deleted, and the view kind is `none`.

**Reserved keys:**

- `appSetting(key: "auth.search-engine.secret")` and `setAppSetting(key: "auth.search-engine.settings", ...)` -> throw the generic invalid-key error.

**Sanitizing:**

- The test connection with a fake whose `failure = .unavailable("boom S user")` -> the detail contains `[redacted]` and not S.
- A 500-character error -> the detail is at most 200 characters.

**Reload:**

- An installed slot handler -> called exactly once per successful update and not on a failed update.

**Resolver:**

- Config section present -> `.managedByConfig`.
- Store settings -> `.store`.
- Neither -> `.none`.
- A stored secret with a mismatched target -> `.store(_, secret: nil)`.

**`SearchEngineCommandTests` (extend):**

- No config section, with valid store settings saved through the API -> `status` reports kind `elasticsearch`.
- Invalid stored settings, for example a bad stored url written with `setAppSetting(allowReserved: true)` -> exit 2 with a message containing only the field name.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P17 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineSettings 2>&1 | tee tmp/search-engine-adapter/P17/settings.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P17 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineCommand 2>&1 | tee tmp/search-engine-adapter/P17/command.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P17 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteServiceSecurityTests 2>&1 | tee tmp/search-engine-adapter/P17/app-settings-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P17 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P17/lint.log; echo exit=${PIPESTATUS[0]}'
wc -l Sources/AppCore/SearchEngineSettingsResolver.swift Sources/AppCore/NoteService+SearchEngineSettings.swift Sources/AppCore/CommandSearchEngine.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0. `NoteServiceSecurityTests` covers the existing reserved `auth.` key behavior.
- All files are under 1000 lines.
- No secret value appears in any log under `tmp/search-engine-adapter/P17/`. Check with `grep -c` for the test secret literal, which must be 0, and record the result.

## Done criteria

- [ ] The resolver, the three admin methods and the CLI resolution are implemented as specified.
- [ ] The secret is bound to `authMode` and the normalized target. A retarget is rejected with no network call.
- [ ] Reserved keys are unreachable through the generic API. Nothing secret appears in views, errors or logs.
- [ ] All verification shows `exit=0` with positive counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
