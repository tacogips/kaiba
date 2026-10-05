# P2 Backend resolution: optional URL, server-default marker, explicit-or-null read

**Status**: Not started
**planId**: P2-backend-resolution
**Wave**: 2
**dependsOn**: P1-descriptor-contract
**Design Reference**: `design-docs/specs/search-engine-adapter.md` B2 (server-default resolution), B3 (persist the marker; identity; secret binding), B4 (read returns explicit or null), B7 (Swift tests), B1 rows A5-A7
**Index**: `impl-plans/active/search-engine-backend-boundary.md`

## Intent and context

After P1, no client receives a default engine URL. This plan makes the
backend accept an omitted URL and resolve it itself:

- "Explicit URL" = the value is non-empty after trimming whitespace.
  Omitted, `nil`, `""` or whitespace-only = server default. Same rule for
  `SearchEngineSettingsInput.url` (update and test connection), the
  stored record and `KaibaSearchEngineConfiguration.url`.
- The server default is resolved only by the existing
  `SearchEngineFactory.defaultURL(for:environment:)` (trimmed
  `KAIBA_MEILISEARCH_URL`, else `fallbackMeilisearchURL`), at every
  resolution, from one environment: `searchEngineSlot.environment` in
  NoteService settings operations, the caller's environment in the
  resolver used by the runtime and the CLI. No `ProcessInfo` reads.
- A server-default save stores the settings JSON **without** a `url` key.
  The resolved URL is never persisted and never returned.
- The settings read returns `url` = the explicit stored or configured URL,
  else `nil`. Never the env/fallback value.
- The secret record target for a server-default save is the normalized
  resolved URL at save time; every use compares it with the URL resolved
  now. On mismatch the secret is not used (fail closed).
- Index identity already derives from the URL the adapter connects to, so
  an env change gives a new identity and the existing activation
  backfills. No new code path for that.

Repository facts (current code after P1):

- `Sources/AppCore/KaibaConfiguration.swift:127-129` `resolvedURL(environment:)` uses `url ?? default` (an empty string is treated as explicit today, which is the bug).
- `Sources/AppCore/SearchEngineSettingsResolver.swift`:
  `StoredSearchEngineSettings` already decodes `url` as optional;
  `connection` maps a missing url to `""`; `resolveSearchEngineSettings(configuration:)`
  has no environment; `storedSearchEngineSettings()` and
  `makeResolvedSearchEngine(configuration:environment:)` call it.
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`:
  line 6 reads `ProcessInfo.processInfo.environment` (A7); line 15 returns
  `config.resolvedURL(environment:)` (A5); `validatedSettings` turns an
  omitted URL into `""` (A6); `StoredSettingsForEncoding.url` is a
  non-optional `String`.
- `Sources/AppCore/CommandSearchEngine.swift:105` calls
  `resolveSearchEngineSettings(configuration:)`.
- `Sources/AppServer/KaibaServerRuntime.swift:141-150` sets
  `searchEngineSlot.setEnvironment(config.environment)` and calls
  `makeResolvedSearchEngine(configuration:environment:)`; its signature
  does not change, so AppServer sources need no edit.

## Non-goals

- No GraphQL schema, DTO, KaibaClient or web change (P1, P3).
- Do not change `SearchEngineSettingsResolution` case shapes
  (`.store(SearchEngineConnectionSettings, secret:)` stays two values);
  `CommandSearchEngine.swift:113` and tests pattern-match it.
- Do not make `SearchEngineConnectionSettings.url` optional; it stays the
  resolved URL the adapter connects to.
- Do not add a `usesServerDefault` field, a migration, or a URL in the
  test-connection result.
- Do not edit `Sources/AppServer/*`, `mise.toml`, compose files or docs.

## writePaths

- `Sources/AppCore/KaibaConfiguration.swift`
- `Sources/AppCore/SearchEngineSettingsResolver.swift`
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`
- `Sources/AppCore/CommandSearchEngine.swift`
- `Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift`
- `Tests/AppCoreTests/SearchEngineSettingsTests.swift`
- `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift`
- `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift`
- `impl-plans/active/search-engine-backend-boundary-p2-backend-resolution.md`
- `tmp/search-engine-backend-boundary/P2`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/SearchEngineSettingsTypes.swift`
- `Sources/AppCore/SearchEngineSlot.swift`
- `Sources/AppCore/SearchEngineSyncOutbox.swift`
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Sources/AppServer/SearchEngineRuntimeController.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngineFactory.swift`: intendedEdit: read-only; call `defaultURL(for:environment:)` and `normalizedTarget(_:)` only.
- `Sources/AppCore/SearchEngineSettingsTypes.swift`: intendedEdit: read-only (P1 owns it); do not change type shapes.
- `Sources/AppServer/KaibaServerRuntime.swift`: intendedEdit: read-only; confirm it already sets the slot environment and passes `config.environment`.
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`: intendedEdit: P1 already changed line 7 to the static adapters list; P2 rewrites the environment source, the read's `url`/`hasSecret`, and URL handling in `validatedSettings` and persistence.
- `tmp/search-engine-backend-boundary/P2`: intendedEdit: evidence logs, hashes.txt and intent.md only.

## artifactRoots

- `tmp/search-engine-backend-boundary/P2`

## File-level changes (contracts pinned)

1. `KaibaConfiguration.swift` (`KaibaSearchEngineConfiguration`):
   - Add `public var explicitURL: String? { get }`: `url` unchanged when
     its trimmed value is non-empty, else `nil`.
   - `resolvedURL(environment:)` returns `explicitURL ?? SearchEngineFactory.defaultURL(for: kind, environment: environment) ?? ""`.
     An explicit value is returned as written (not trimmed); the existing
     test expects `"https://search.example"` unchanged.
   - Update the `url` doc comment: absent, empty or whitespace-only means
     the server default.
   - `SearchEngineFactory.make(configuration:environment:)` already calls
     `resolvedURL`, so the config path gets the empty-string fix with no
     factory edit.
2. `SearchEngineSettingsResolver.swift`:
   - Signature becomes
     `func resolveSearchEngineSettings(configuration: KaibaSearchEngineConfiguration?, environment: [String: String]) throws -> SearchEngineSettingsResolution`
     (required parameter, no default value: a default would hide the A7
     bug).
   - For a stored record, the connection URL = the trimmed-non-empty
     stored `url` as written, else
     `SearchEngineFactory.defaultURL(for: stored.kind, environment:) ?? ""`.
     The secret match compares `storedSecret.target` with
     `normalizedTarget(<that resolved URL>)`.
   - `makeResolvedSearchEngine(configuration:environment:)` passes its
     `environment` through.
   - `storedSearchEngineSettings()` becomes
     `storedSearchEngineSettings(environment: [String: String])`.
   - Add `internal func storedSearchEngineExplicitURL() throws -> String?`:
     the stored record's trimmed-non-empty `url` as written, `nil` when
     the record has no explicit URL, has `kind: "none"`, or is absent.
3. `NoteService+SearchEngineSettings.swift`:
   - `searchEngineSettings()`: `let environment = searchEngineSlot.environment`
     (delete the `ProcessInfo` read). Config case: `url: config.explicitURL`.
     Store case: settings from `storedSearchEngineSettings(environment:)`,
     `url: try storedSearchEngineExplicitURL()`, `hasSecret` compares the
     stored secret target with `normalizedTarget(settings.url)` (the
     resolved URL). `adapters` stays the static list (P1).
   - `validatedSettings(_:timeoutCap:makeEngine:)`: after the kind check,
     compute `explicitURL` from `input.url` (trimmed non-empty -> value as
     written, else `nil`); the connection URL is
     `explicitURL ?? SearchEngineFactory.defaultURL(for: input.kind, environment: searchEngineSlot.environment) ?? ""`.
     `normalizedTarget` and the secret rules then use the resolved URL
     exactly as today. Carry `explicitURL` into the persisted JSON.
   - `StoredSettingsForEncoding.url` becomes `String?` and is set from
     `explicitURL`, so a server-default save encodes no `url` key
     (synthesized `Encodable` uses `encodeIfPresent` for optionals; prove
     it with the raw-row test below).
   - `testSearchEngineConnection`: no logic change; it inherits the
     resolved URL through `validatedSettings`, so `makeEngine` receives
     the resolved URL and the detail stays sanitized.
4. `CommandSearchEngine.swift:105`: pass `environment: environment`.

## Pitfalls

- Never write the resolved URL into `auth.search-engine.settings`.
- Never return the resolved URL in the view, an error, a diagnostic, a
  test-connection detail or a log line. Errors stay field names
  (`searchEngine.url`, `searchEngine.secret`).
- Keep explicit URLs byte-for-byte as entered (the existing test stores
  `"https://search.internal:7700/"` and reads it back unchanged).
- The secret target for a server-default save is computed from the
  resolved URL, not from the empty input.
- `kind: "none"` handling is unchanged.
- Use `searchEngineSlot.environment` in NoteService paths; never
  `ProcessInfo.processInfo.environment`.
- Unknown kinds still fail with `searchEngine.kind` before URL resolution.
- Keep every Swift file under 1000 lines (`NoteService+SearchEngineSettings.swift`
  is 257 today).

## Tests (input or situation -> expected outcome)

`Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift`:

- decode `{"url":""}` -> `explicitURL == nil`; `resolvedURL(environment: [:]) == SearchEngineFactory.fallbackMeilisearchURL`.
- decode `{"url":"   "}`, env `["KAIBA_MEILISEARCH_URL": " https://env.example "]` -> `resolvedURL == "https://env.example"`.
- url absent: env unset -> fallback; env `""` -> fallback; env set -> trimmed env value.
- explicit `"https://search.example"` with env set -> `"https://search.example"`; `explicitURL == "https://search.example"`.
- `SearchEngineFactory.make(configuration:` decoded `{"url":""}` `, environment: [:])` -> identity `meilisearch:http://127.0.0.1:7700/kaiba-notes-v1` (no throw).

`Tests/AppCoreTests/SearchEngineSettingsTests.swift` (create services
with `SearchEngineSlot()` + `setEnvironment`, imitating
`testConfigManagedViewIsReadOnly`):

- Update existing `resolveSearchEngineSettings(configuration:)` calls to
  pass `environment: [:]`; their assertions stay as they are.
- env A `["KAIBA_MEILISEARCH_URL": "https://a.example"]`, update
  `{kind: meilisearch, authMode: none}` with url `nil`, then `""`, then
  `"  "` -> each time the raw
  `appSetting(key: NoteService.searchEngineSettingsKey, allowReserved: true)`
  JSON has no `url` key; the view has `kind == "meilisearch"` and
  `url == nil`.
- explicit `"https://search.internal:7700/"` -> raw JSON has that `url`;
  the view returns it unchanged.
- config-managed slot with `KaibaSearchEngineConfiguration(kind: "meilisearch")`
  (no url) and env A -> view `url == nil`; with url `"https://config.internal"`
  -> view `url == "https://config.internal"`.
- default settings stored; `makeResolvedSearchEngine(configuration: nil, environment: A)`
  identity contains `a.example`; with env B (`https://b.example`) the
  identity contains `b.example`; `activateSearchEngineSync(indexIdentity:)`
  with A returns `true`, then with B returns `true` (backfill on change).
- default settings saved under slot env A with `authMode: apiKey`, secret
  `"key-a"` -> `resolveSearchEngineSettings(configuration: nil, environment: A)`
  gives secret `"key-a"`; with env B the secret is `nil` and
  `makeResolvedSearchEngine(configuration: nil, environment: B)` throws
  `SearchEngineSettingsError.invalid(field: "searchEngine.secret")`; after
  `slot.setEnvironment(B)` the view's `hasSecret` is `false`.
- slot env A, `testSearchEngineConnection(input with url nil, authMode none) { settings, _ in ... }`
  -> the closure receives `settings.url == "https://a.example"`; returns
  `FakeSearchEngine()`; the result detail does not contain `a.example`.
- slot env `["KAIBA_MEILISEARCH_URL": "http://remote.example"]` (plain
  http, non-loopback) -> update with url `nil` throws
  `invalid(field: "searchEngine.url")` and the raw settings row is still
  `nil`; test connection returns status `.invalidSettings`, detail
  `"searchEngine.url"`.

`Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift` (service
slot env `["KAIBA_MEILISEARCH_URL": "https://engine-only.internal"]`):

- `updateSearchEngineSettings(input: {kind: "meilisearch", authMode: "none"})`
  (no url) -> `result.accepted == true`, `value.url` is JSON `null`,
  `value.kind == "meilisearch"`.
- the same with `url: ""` -> same outcome.
- `testSearchEngineConnection(input: {kind: "meilisearch", authMode: "apiKey"})`
  (no url, no secret, nothing stored) -> `accepted == true`,
  `value.status == "invalid-settings"`, `value.detail == "searchEngine.secret"`
  (proves the omitted URL passed URL validation with no network call).
- the serialized responses of all three calls and of a following
  `searchEngineSettings` read do not contain `engine-only.internal`.

`Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift` (new
test; imitate the existing test and reuse `RuntimeMeilisearchFakeEngine`):

- slot env A `https://env-a.example`; controller `makeEngine` =
  `try service.makeResolvedSearchEngine(configuration: nil, environment: slot.environment)`;
  `makeLoop` wraps a fake engine (no network); update settings with url
  omitted, `authMode: "none"` -> `slot.engine?.indexIdentity ==
  "meilisearch:https://env-a.example/kaiba-notes-v1"`; then
  `slot.setEnvironment(B: https://env-b.example)` and
  `await controller.reload()` -> identity
  `"meilisearch:https://env-b.example/kaiba-notes-v1"`; stop the
  controller.

## Verification

```bash
mkdir -p tmp/search-engine-backend-boundary/P2
bash -c 'mise run build 2>&1 | tee tmp/search-engine-backend-boundary/P2/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "SearchEngine|Meilisearch|KaibaSearchEngine" 2>&1 | tee tmp/search-engine-backend-boundary/P2/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-backend-boundary/P2/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'grep -rn "ProcessInfo" Sources/AppCore/NoteService+SearchEngineSettings.swift Sources/AppCore/SearchEngineSettingsResolver.swift | tee tmp/search-engine-backend-boundary/P2/guard-processinfo.log; test ! -s tmp/search-engine-backend-boundary/P2/guard-processinfo.log'
wc -l Sources/AppCore/KaibaConfiguration.swift Sources/AppCore/SearchEngineSettingsResolver.swift Sources/AppCore/NoteService+SearchEngineSettings.swift Sources/AppCore/CommandSearchEngine.swift Tests/AppCoreTests/SearchEngineSettingsTests.swift Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift | tee tmp/search-engine-backend-boundary/P2/wc.log
```

Expected evidence:

- build exit 0.
- swift test exit 0; `Executed N tests, with 0 failures` with N > 0
  (MeilisearchLiveTests may report skips without `KAIBA_MEILISEARCH_URL`;
  skips are not evidence and are not counted as behavior). Record the
  swift-testing count too if the filter selects any (M > 0), otherwise
  record it as not applicable.
- lint exit 0, 0 serious violations.
- The ProcessInfo guard exits 0 with an empty log.
- Every touched Swift file is under 1000 lines.

## Done criteria

- [ ] All B7 Swift cases above exist and pass.
- [ ] A server-default save leaves no `url` key in `auth.search-engine.settings` (raw-row assertion).
- [ ] The view's `url` is never the env or fallback value (config and store cases tested).
- [ ] `resolveSearchEngineSettings` requires `environment`; the CLI passes its environment; no ProcessInfo read in the settings paths.
- [ ] Secret fails closed after an env retarget (tested).
- [ ] Progress Log updated with commands, exit codes, counts and log paths.

## Progress Log

- 2026-10-05: Plan created.
