# P12 Delta contract: adapter-neutral types, settings types, shared engine slot

**Status**: Ready
**planId**: P12-delta-contract
**Wave**: 1
**dependsOn**: none among dispatched plans. Accepted dependencies: P1-core-contract and P5-engine-query-service, both in commit b466ced.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` sections D1 "Document fields", D2 "Protocol additions", D3 "Signals", D5 "Normalized connection settings", "AppCore API" and "Hot-swap"
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

The delta adds ontology-aware indexing (D1), ontology search with facets (D2), hybrid related notes with reasons (D3) and admin engine settings with hot-swap (D5). Several wave-2 to wave-4 plans build against the same value types. This plan pins every shared type up front, so those plans can run in parallel without editing a shared file.

This plan adds types and one shared reference holder only. It adds no behavior beyond these four:

- defaults that reproduce today's behavior exactly;
- a protocol-extension default for `searchPage`;
- `NoteService.searchEngine` backed by a shared slot;
- a richer `FakeSearchEngine` for the tests of later plans.

Repository facts:

- `Sources/AppCore/SearchEngine.swift` holds the P1 protocol and value types (197 lines).
- `Sources/AppCore/NoteService.swift` is 942 lines.
  - `public var searchEngine: (any SearchEngine)?` is a stored property at line 87.
  - `init(driver:autoActionDispatcher:autoActionDiagnosticRecorder:agentExecutionAdmission:autoActionDispatchLeaseStaleness:changeObserver:)` is at line 119.
  - Shared reference holders that every copy shares follow the pattern of `autoActionDispatchTasks` and `notebookIngestExecutionRegistry` (lines 90 and 94, both assigned in init).
- `NoteService` is a struct. `scoped(to:)` (`NoteService+Users.swift`) does `var copy = self`, so a class-typed `let` property is shared by every scoped copy.
- `Tests/AppCoreTests/FakeSearchEngine.swift` is the P1 fake (143 lines). Its filter logic lives in `matches(_:document:)`.

## Non-goals

- No Elasticsearch change; that is P13.
- No query-service change; that is P15.
- No settings persistence; that is P17.
- No GraphQL; that is P18.
- No server wiring; that is P19.
- No change to `searchNotes` or any existing GraphQL field.
- No new SwiftPM target or dependency.

## writePaths

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/SearchEngineSettingsTypes.swift` (new)
- `Sources/AppCore/SearchEngineSlot.swift` (new)
- `Sources/AppCore/NoteService.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`
- `Tests/AppCoreTests/SearchEngineDeltaContractTests.swift` (new)
- `impl-plans/active/search-engine-adapter-p12-delta-contract.md`

## sharedPaths (read-only)

- `Sources/AppCore/KaibaConfiguration.swift`: read-only. `KaibaSearchEngineConfiguration`, which the slot stores.
- `Sources/AppCore/NoteService+Users.swift`: read-only. `scoped(to:)` copy semantics.
- `Tests/AppCoreTests/NoteServiceTests.swift`: read-only. The `makeService` helpers.

## File-level changes

### `Sources/AppCore/SearchEngine.swift` (additive only)

Every type is `public`, `Equatable` and `Sendable`, with a public memberwise-style init. Every new stored property on an existing type gets a defaulted init parameter appended at the end of the existing init. Existing call sites must compile unchanged: tests, `ElasticsearchLiveTests`, `SearchIndexSynchronizer`, and the GraphQL DTO init from `NoteEngineSearchHit`.

**D1 document fields:**

- `struct SearchIndexTagApplication { tagId: TagID; provenance: String }`. The provenance is `human`, `ai` or `system`.
- `struct SearchIndexPathTag { tagId: TagID; name: String; tagClass: String?; isDirect: Bool }`
- `SearchIndexDocument` gains:
  - `tagApplications: [SearchIndexTagApplication] = []`
  - `pathTags: [SearchIndexPathTag] = []`
  - `outgoingLinkNoteIds: [NoteID] = []`
  - `incomingLinkNoteIds: [NoteID] = []`

**D2 filters, query, facets and page:**

- `struct SearchEngineTagClassFilter { tagClass: String; tagId: TagID? }`
- `SearchEngineFilter` gains `hierarchyTagIds: [TagID] = []` and `tagClassFilters: [SearchEngineTagClassFilter] = []`.
- `struct SearchEngineFacetRequest { tagClassLimit: Int; tagLimit: Int }`. Its init defaults are `tagClassLimit: 10` and `tagLimit: 15`.
- `SearchEngineQuery` gains `expansionTagIds: [TagID] = []` and `facets: SearchEngineFacetRequest? = nil`.
- `struct SearchEngineFacetBucket { value: String; count: Int }`. Tag buckets carry the tag id raw value.
- `struct SearchEngineFacets { tagClasses: [SearchEngineFacetBucket]; tags: [SearchEngineFacetBucket] }`
- `struct SearchEngineSearchPage { hits: [SearchEngineHit]; facets: SearchEngineFacets? }`

**Reasons:**

- `enum SearchEngineHitReasonKind: String`, with these cases and raw values exactly:
  - `textMatch = "text-match"`
  - `tagMatch = "tag-match"`
  - `tagHierarchyMatch = "tag-hierarchy-match"`
  - `textSimilarity = "text-similarity"`
  - `sharedTag = "shared-tag"`
  - `relatedTag = "related-tag"`
  - `sharedEntity = "shared-entity"`
  - `linked = "linked"`
- `struct SearchEngineHitReason { kind: SearchEngineHitReasonKind; tagNames: [String] = [] }`
- `SearchEngineHit` gains `reasons: [SearchEngineHitReason] = []`.

**D3 related signals:**

- `struct SearchEngineClassTag { tagClass: String; tagId: TagID }`
- `struct SearchEngineRelatedSignals { sourceNoteId: NoteID; sharedTagIds: [TagID]; nearTagIds: [TagID]; ancestorTagIds: [TagID]; entityTags: [SearchEngineClassTag] }`
- `SearchEngineRelatedQuery` gains `signals: SearchEngineRelatedSignals? = nil`.

**Protocol:**

- Add the requirement `func searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage`.
- In the existing `public extension SearchEngine`, add a default implementation that returns `SearchEngineSearchPage(hits: try await search(query), facets: nil)`.
- Do not change the existing five requirements.

**Service-facing results:**

- `NoteEngineSearchHit` gains `reasons: [SearchEngineHitReason] = []`.
- `struct NoteEngineTagFacet { tagId: TagID; name: String; tagClass: String?; count: Int }`
- `struct NoteEngineSearchFacets { tagClasses: [SearchEngineFacetBucket]; tags: [NoteEngineTagFacet] }`
- `struct NoteEngineSearchPage { hits: [NoteEngineSearchHit]; facets: NoteEngineSearchFacets? }`

If the file would exceed about 450 lines, move the D2, D3 and reason types into a new `Sources/AppCore/SearchEngineOntologyTypes.swift`. Only do that if needed, and record the move in the Progress Log. That path is then part of this plan's write scope by amendment.

### `Sources/AppCore/SearchEngineSettingsTypes.swift` (new)

These types are `public`, `Equatable` and `Sendable`:

- `enum SearchEngineAuthMode: String, CaseIterable { case none, basic, apiKey }`
- `struct SearchEngineAdapterDescriptor { kind: String; displayName: String; authModes: [SearchEngineAuthMode] }`
- `struct SearchEngineConnectionSettings { kind: String; url: String; indexPrefix: String; authMode: SearchEngineAuthMode; username: String?; verifyTLS: Bool; requestTimeoutSeconds: Int }`
  - Init defaults: `indexPrefix "kaiba"`, `authMode .none`, `username nil`, `verifyTLS true`, `requestTimeoutSeconds 10`.
  - It is also `Codable`. P17 persists it as JSON.
- `enum SearchEngineSettingsManagement: String { case config = "config", store = "store", unset = "default" }`
- `struct SearchEngineSettingsView { managedBy: SearchEngineSettingsManagement; kind: String; url: String?; indexPrefix: String?; authMode: SearchEngineAuthMode; username: String?; hasSecret: Bool; verifyTLS: Bool; requestTimeoutSeconds: Int; adapters: [SearchEngineAdapterDescriptor]; active: Bool }`
  - There is deliberately no secret field.
- `struct SearchEngineSettingsInput { kind: String; url: String?; indexPrefix: String?; authMode: String?; username: String?; secret: String?; clearSecret: Bool; verifyTLS: Bool?; requestTimeoutSeconds: Int? }`
  - Its `CustomStringConvertible` and `CustomDebugStringConvertible` descriptions must print `secret` as `[redacted]` when it is set. This keeps the secret out of any interpolation or log.
- `enum SearchEngineConnectionTestStatus: String`, with these cases:
  - `available`
  - `unhealthy`
  - `unavailable`
  - `rejected`
  - `invalidResponse = "invalid-response"`
  - `invalidSettings = "invalid-settings"`
- `struct SearchEngineConnectionTestResult { available: Bool; status: SearchEngineConnectionTestStatus; detail: String }`
- `enum SearchEngineSettingsError: Error, CustomStringConvertible`, with these cases:
  - `managedByConfig`, whose description is `"settings-managed-by-config"`;
  - `invalid(field: String)`, whose description is `"invalid-settings: <field>"`. The description never includes a value.
- `struct SearchEngineReloadOutcome { active: Bool; indexIdentity: String? }`

### `Sources/AppCore/SearchEngineSlot.swift` (new)

`public final class SearchEngineSlot: @unchecked Sendable` guards its state with `NSLock`. Imitate the lock style of `FakeSearchEngine`, using `lock.withLock`.

Members:

- `public init(engine: (any SearchEngine)? = nil)`
- `public var engine: (any SearchEngine)? { get }`
- `public func replace(_ engine: (any SearchEngine)?)`
- `public var managedConfiguration: KaibaSearchEngineConfiguration? { get }` and `public func setManagedConfiguration(_ configuration: KaibaSearchEngineConfiguration?)`. The server sets these once at start. P17 uses them for the config-precedence rule.
- `public var environment: [String: String] { get }` and `public func setEnvironment(_ environment: [String: String])`. These hold the process environment for config-mapped views; the default is `[:]`.
- `public func setReloadHandler(_ handler: (@Sendable () async -> SearchEngineReloadOutcome)?)`
- `public func reload() async -> SearchEngineReloadOutcome?`. It returns nil when no handler is installed.

**Pitfall.** Copy the handler out under the lock, then await it outside the lock. Never hold `NSLock` across `await`.

### `Sources/AppCore/NoteService.swift`

1. Replace the stored `public var searchEngine: (any SearchEngine)?` with:
   - `public let searchEngineSlot: SearchEngineSlot`, with a doc comment saying that scoped copies share it;
   - a computed `public var searchEngine: (any SearchEngine)? { get { searchEngineSlot.engine } nonmutating set { searchEngineSlot.replace(newValue) } }`.
2. Append the init parameter `searchEngineSlot: SearchEngineSlot = SearchEngineSlot()` last, and assign it in init.
3. Grep for any other designated initializer of `NoteService` in `Sources/AppCore` with `grep -n "self.changeObserver =" Sources/AppCore/*.swift`. If one exists, give it the same assignment. Record the result.
4. Budget: the file must stay at or under 950 lines.

### `Tests/AppCoreTests/FakeSearchEngine.swift`

Keep every existing knob and its behavior. Add these:

- In `matches(_:document:)`:
  - `hierarchyTagIds`: a non-empty list requires that `document.pathTags` contain any of the ids.
  - Each entry in `tagClassFilters` must match a path tag with that `tagClass`, and with that `tagId` when one is given.
- `scriptedFacets: SearchEngineFacets?`, a locked knob like `scriptedHits`.
- `recordedSearchPages: [SearchEngineQuery]`
- An implementation of `searchPage(_:)`, which delegates to the existing `search(_:)`. In order:
  1. `let hits = try await search(query)`. The existing `search` already throws `failure`, appends the query to `recordedSearches` before it branches, and returns either `scriptedHits` unchanged (reasons included) or the matching logic.
  2. Under the lock, append the query to `recordedSearchPages`.
  3. Return `SearchEngineSearchPage(hits: hits, facets: query.facets != nil ? scriptedFacets : nil)`.

  Every `searchPage` call, scripted or not, appends exactly one entry to `recordedSearches` and exactly one to `recordedSearchPages`. A call that throws `failure` appends to neither, as `search` does today.

  Do not reimplement the scripted or matching branches inside `searchPage`. The accepted P5 tests (`SearchEngineQueryTests`, `SearchEngineAccessTests`) set `scriptedHits` and then assert on `recordedSearches` (`count`, `.last?.from`, `.size`, `.text`, `.filter`). After P15 routes `engineSearchNotes` through `searchPage`, those assertions must still hold, and P15 may not edit this fake.
- `relatedNotes` keeps its logic. It still records the query, so later plans can assert on `signals`.

## Pitfalls

- **Defaults are behavior.** With the defaults, every existing test must pass unchanged, including the P1 contract tests, the P5 query and access tests, and the P4 drain tests.
- **Do not reorder existing init parameters.** Only append new ones.
- **`nonmutating set`.** Code like `var service = ...; service.searchEngine = fake`, as in the P5 tests, must keep compiling.
- **One slot per `NoteService.init`.** Two independently constructed services must not share an engine. A test asserts this.
- **Do not log** `SearchEngineSettingsInput.secret`. Redact it in the descriptions.
- **Swift 6 strict concurrency.** The slot is `@unchecked Sendable` with all state under the lock. The handler closure type is `@Sendable`.

## Tests (`SearchEngineDeltaContractTests`, XCTest)

- A `SearchIndexDocument` built with the old init arguments has empty D1 fields. Both `SearchEngineFilter` and `SearchEngineQuery` built with old arguments have empty new fields and nil facets.
- A minimal custom engine that implements only the five base requirements -> `searchPage` returns its `search` hits with nil facets.
- `var a = NoteService(...)`; `let b = a.scoped(to: someUser)` (or any copy); `a.searchEngine = FakeSearchEngine()` -> `b.searchEngine` is non-nil, and `b.isSearchEngineEnabled` is true.
- Two separately constructed services -> setting an engine on one leaves the other nil.
- Slot with no handler -> `reload()` returns nil. With a handler that returns `SearchEngineReloadOutcome(active: true, indexIdentity: "x")` -> `reload()` returns it.
- `SearchEngineSettingsInput(secret: "s3cr3t", ...)` -> `String(describing:)` and `String(reflecting:)` do not contain `s3cr3t`.
- `SearchEngineHitReasonKind` raw values equal the eight pinned strings.
- `FakeSearchEngine` with `scriptedHits = [SearchEngineHit(noteId: N, score: 1, highlight: nil, reasons: [SearchEngineHitReason(kind: .tagMatch)])]`, and one `searchPage` call -> `recordedSearches.count == 1`, `recordedSearchPages.count == 1`, and the returned hits equal the scripted hits with their reasons unchanged. A second call without scripted hits -> both counts are 2.
- `FakeSearchEngine` with `failure` set -> `searchPage` throws, and both recorded lists stay empty.
- `FakeSearchEngine` with a document whose `pathTags` contain tag A (`isDirect: false`) -> a search with `hierarchyTagIds: [A]` returns it, and `[B]` does not. A class filter `person` matches only a document with a path tag of class `person`.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P12 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineDeltaContract 2>&1 | tee tmp/search-engine-adapter/P12/contract.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P12 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngine 2>&1 | tee tmp/search-engine-adapter/P12/search-engine-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P12 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchIndexSynchronizer 2>&1 | tee tmp/search-engine-adapter/P12/drain-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P12 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P12/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "searchEngineSlot\|nonmutating set" Sources/AppCore/NoteService.swift
wc -l Sources/AppCore/SearchEngine.swift Sources/AppCore/SearchEngineSettingsTypes.swift Sources/AppCore/SearchEngineSlot.swift Sources/AppCore/NoteService.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with a positive count.
  - The new `SearchEngineDeltaContractTests` is XCTest, so record its `Executed N tests, 0 failures`.
  - The `--filter SearchEngine` regression run matches both XCTest suites and the swift-testing suites `SearchEngineContractTests` and `KaibaSearchEngineConfigurationDecodingTests`. Record both positive counts, each labeled with its framework.
- `NoteService.swift` has at most 950 lines.
- `mise run lint` shows `exit=0`.

## Done criteria

- [ ] All pinned types and members exist with the exact names and raw values above.
- [ ] `searchEngine` is slot-backed and shared by scoped copies; separate services do not share it.
- [ ] `FakeSearchEngine` supports the hierarchy and class filters, `searchPage`, and `scriptedFacets`.
- [ ] Every existing SearchEngine test still passes. All verification shows `exit=0` with positive counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
