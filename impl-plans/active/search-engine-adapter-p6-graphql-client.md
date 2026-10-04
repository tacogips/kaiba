# P6 GraphQL fields and KaibaClient operations

**Status**: Ready
**planId**: P6-graphql-client
**Wave**: 3
**dependsOn**: P1-core-contract, P5-engine-query-service
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE5
**Index**: `impl-plans/active/search-engine-adapter.md` (pinned GraphQL SDL, statuses and limits)

## Intent and context

This plan exposes engine-backed search, related notes and the capability
flag through the GraphQL contract and the hand-written KaibaClient SDK.
`searchNotes` and every existing field stay unchanged.

Repository facts:

- Query fields are declared one per physical line in
  `Sources/AppGraphQL/GraphQLContractProjector.swift`, because contract
  tests assert those strings. Types live in
  `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`.
- Field registries in
  `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`:
  - `supportedNoteGraphQLFields`
  - `noteGraphQLQueryFields`
  - `noteGraphQLRootSelectionTypes`
  - `noteGraphQLSelectionFields`
- Dispatch is in `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`. See
  the `case "searchNotes"` and `case "proposeNoteLinks"` patterns.
- Variable validators are in
  `Sources/AppGraphQL/NoteGraphQLDocumentVariables.swift`:
  `validatedLimit`, `validatedGraphLimit` and `validatedOffset`.
- Patterns to imitate:
  - `NoteGraphQLService+TagEntity.swift` for an extension file;
  - `noteResult { }` and `graphQLNoteResult(for:)` in
    `NoteGraphQLService.swift`;
  - the payload with extra fields in
    `UserAgentCredentialPayload` / `featureEnabled`.
- `NoteGraphQLService.swift` is 956 lines. Do not add to it.
- KaibaClient: `Sources/KaibaClient/KaibaOperations.swift` has
  `searchNotes` at line 140. The helpers `operation(...)`, `noteFields`,
  `tagFields` and `tagDefinitionFields` are `private` (lines 781 and 833).
  `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift` is 997
  lines. Do not add to it.

## Non-goals

- No change to `searchNotes`, `NoteSearchResult`, or any existing field or
  type.
- No admin reindex mutation.
- No web changes. That is P9.

## writePaths

- `Sources/AppGraphQL/GraphQLContractProjector.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentVariables.swift`
- `Sources/AppGraphQL/NoteGraphQLService+SearchEngine.swift`
- `Sources/KaibaClient/KaibaOperations.swift`
- `Sources/KaibaClient/KaibaOperations+SearchEngine.swift`
- `Sources/KaibaClient/KaibaModels.swift`
- `Tests/AppGraphQLTests/SearchEngineGraphQLTests.swift`
- `Tests/AppGraphQLTests/NoteGraphQLSchemaInventoryTests.swift`
- `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`
- `impl-plans/active/search-engine-adapter-p6-graphql-client.md`

New files: `Sources/AppGraphQL/NoteGraphQLService+SearchEngine.swift`, `Sources/KaibaClient/KaibaOperations+SearchEngine.swift`, `Tests/AppGraphQLTests/SearchEngineGraphQLTests.swift`, `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/NoteService+SearchEngine.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngine.swift`: read-only: `SearchEngineError` and
  `NoteEngineSearchHit`.
- `Sources/AppCore/NoteService+SearchEngine.swift`: read-only: P5 service API.
- `Sources/AppGraphQL/NoteGraphQLService.swift`: read-only: `noteResult` and
  `graphQLNoteResult`; the file must stay at 956 lines.
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`: read-only: `GraphQLNoteDTO`.

## File-level changes

### SDL

- Add the 3 pinned Query lines to `type Query` in
  `GraphQLContractProjector.swift`, after `agenticSearch`. Each is one
  physical line, verbatim from the index.
- Add the 3 pinned types to `graphQLNoteSchemaContract`, after
  `NoteSearchResult`.
- Extend the header comment with the limits: `engineSearchNotes.limit`
  0...200, `offset` 0...1000, and `relatedNotes.limit` 0...20.

### Registries (`NoteGraphQLDocumentExecutorSupport.swift`)

- Add `searchEngineCapability`, `engineSearchNotes` and `relatedNotes` to
  both `supportedNoteGraphQLFields` and `noteGraphQLQueryFields`.
- `noteGraphQLRootSelectionTypes`:
  - `searchEngineCapability` maps to `SearchEngineCapabilityPayload`;
  - the other two map to `EngineNoteSearchQueryPayload`.
- `noteGraphQLSelectionFields`:
  - `SearchEngineCapabilityPayload` maps to
    `["result": "ControlPlaneResult", "enabled": nil]`;
  - `EngineNoteSearchQueryPayload` maps to
    `noteGraphQLQueryPayloadFields(valueType: "EngineNoteHit")`;
  - `EngineNoteHit` maps to
    `["note": "Note", "snippet": nil, "score": nil]`.

### Variables (`NoteGraphQLDocumentVariables.swift`)

- Add `let noteGraphQLMaximumEngineSearchOffset = 1_000`.
- Add `func validatedEngineSearchOffset(_ value: Int?) throws -> Int`. It
  defaults to 0. Out of range, it throws `invalidVariable("offset must be
  between 0 and 1000 for engineSearchNotes")`.

### Dispatch (`NoteGraphQLDocumentExecutor.swift`)

Three cases after `"agenticSearch"`, or wherever query cases are grouped:

- `searchEngineCapability` calls `service.searchEngineCapability()`.
- `engineSearchNotes`:
  - `query`: `requiredString`;
  - `notebookId`: `optionalIdentifier`;
  - `tagFilter`: `optionalStringArray ?? []`;
  - `limit`: `validatedLimit(default 20)`;
  - `offset`: `validatedEngineSearchOffset`.
- `relatedNotes`:
  - `noteId`: `requiredIdentifier`;
  - `limit`: `validatedGraphLimit(default 8)`.

### `NoteGraphQLService+SearchEngine.swift` (new)

- DTOs:
  - `public struct GraphQLSearchEngineCapabilityPayload: Codable, Equatable, Sendable`
    with `result: GraphQLControlPlaneResult` and `enabled: Bool`;
  - `public struct GraphQLEngineNoteHitDTO` with `note: GraphQLNoteDTO`,
    `snippet: String`, `score: Double`, and `init(hit: NoteEngineSearchHit)`.
- `public extension GraphQLNoteGraphQLService`:
  - `func searchEngineCapability() async -> GraphQLSearchEngineCapabilityPayload`
    returns `.ok` with `enabled: service.isSearchEngineEnabled`. It makes no
    network call.
  - `func engineSearchNotes(query:notebookId:tagFilter:limit:offset:) async -> GraphQLNoteQueryResult<[GraphQLEngineNoteHitDTO]>`
  - `func relatedNotes(noteId:limit:) async -> GraphQLNoteQueryResult<[GraphQLEngineNoteHitDTO]>`
- Error mapping, inside an async `do/catch`. `noteResult` is synchronous,
  so do not use it.
  - `SearchEngineError.notConfigured` gives
    `GraphQLControlPlaneResult(accepted: false, status: "feature-disabled", diagnostics: ["search engine is not configured"])`.
  - Any other `SearchEngineError` gives `accepted: false`,
    `status: "search-engine-unavailable"` and
    `diagnostics: ["search engine unavailable"]`. Never include the
    engine's error text in a public diagnostic.
  - Anything else goes through `graphQLNoteResult(for:)`, which keeps
    `not_found` and `invalid_request`.

### KaibaClient

- In `KaibaOperations.swift`, change only the access level of
  `private func operation`, `private static let tagFields`,
  `private static let tagDefinitionFields` and
  `private static let noteFields` to internal, by removing `private`. No
  other edits.
- In `KaibaModels.swift`, add:
  - `public struct KaibaEngineNoteHit: Codable, Equatable, Sendable` with
    `note: KaibaNote`, `snippet: String`, `score: Double`;
  - `public struct KaibaSearchEngineCapabilityPayload` with
    `result: KaibaControlPlaneResult` and `enabled: Bool`.

  Conform the capability payload to
  `KaibaControlPlaneDiagnosticsSanitizable`, following the
  `KaibaOperationPayload` extension pattern at the top of
  `KaibaOperations.swift`. Put that extension in the new file.
- In `KaibaOperations+SearchEngine.swift`, `extension KaibaClient` adds:
  - `public func searchEngineCapability() async throws -> KaibaSearchEngineCapabilityPayload`
  - `public func engineSearchNotes(query: String, notebookId: KaibaNotebookID? = nil, tagFilter: [String] = [], limit: Int = 20, offset: Int = 0) async throws -> KaibaValuePayload<[KaibaEngineNoteHit]>`
  - `public func relatedNotes(noteId: KaibaNoteID, limit: Int = 8) async throws -> KaibaValuePayload<[KaibaEngineNoteHit]>`

  Documents use the `root:` alias and select
  `result { accepted status diagnostics }`. Value selections are
  `note { noteFields } snippet score` and `enabled`. Mirror
  `searchNotes`: only send `tagFilter` when it is non-empty.

## Pitfalls

- Every new root field must appear in ALL four registries and in the
  dispatch, or the inventory test fails, or the executor rejects the field
  as unsupported.
- Contract tests compare `type Query` lines as whole strings. Keep each new
  field on one physical line, with exactly the pinned spelling.
- Do not catch `SearchEngineError` inside `noteResult`, because its body is
  synchronous. Use an explicit async `do/catch`.
- Do not leak engine error details to clients. The diagnostic is the fixed
  string.
- `KaibaClientPublicAPITests` only checks that the endpoint does not
  publish raw URL members. The new public symbols must not add any URL-typed
  public member. Do not edit that test.

## Tests

`SearchEngineGraphQLTests` (XCTest, AppGraphQLTests):

- Build a `GraphQLNoteGraphQLService` the way
  `NoteGraphQLSearchPaginationTests.makeNoteGraphQLService` does. Add a
  private fake `SearchEngine` in this file with scripted hits and an
  optional error. AppCoreTests' fake is not visible from this target.
- Run the queries through `NoteGraphQLDocumentExecutor` with GraphQL
  documents.
- Cases:
  - Capability with no engine gives `enabled false` and accepted. With an
    engine it gives `enabled true`.
  - `engineSearchNotes` with no engine gives `accepted false`,
    `status "feature-disabled"`.
  - A fake throwing `.unavailable("secret-host")` gives status
    `"search-engine-unavailable"`, and the diagnostics do not contain
    `"secret-host"`.
  - Happy path: hits for existing notes return note, snippet and score in
    order.
  - `limit 201` gives an invalidVariable error. `offset 1001` gives
    `"offset must be between 0 and 1000 for engineSearchNotes"`.
    `relatedNotes limit 21` gives the graph-limit error.
  - `relatedNotes` with an unknown noteId gives `status "not_found"`.
  - Empty query gives `invalid_request`.
  - `searchNotes` still returns the same payload with and without an engine
    attached (regression).
- `NoteGraphQLSchemaInventoryTests`: add the 3 fields to the expected
  `queryFields` set.

`KaibaSearchEngineOperationTests` (swift-testing, KaibaClientTests):

- The transports in `KaibaTypedOperationContractTests` are private. Define
  your own private recording transport conforming to
  `KaibaHTTPTransporting`, imitating
  `KaibaTypedOperationContractTests.swift:TypedContractTransport`.
- Assert that each new operation:
  - sends the expected document root field;
  - sends the expected variables: `tagFilter` omitted when empty, plus
    `limit` and `offset`;
  - decodes a scripted response into the typed models.
- Assert that each sent document contains the pinned root field name and
  argument names.
- Assert that a not-accepted result with status `feature-disabled` decodes,
  rather than throwing.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineGraphQL 2>&1 | tee tmp/search-engine-adapter/P6/graphql.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteGraphQLSchemaInventory 2>&1 | tee tmp/search-engine-adapter/P6/inventory.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaSearchEngineOperation 2>&1 | tee tmp/search-engine-adapter/P6/client.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaClientTests 2>&1 | tee tmp/search-engine-adapter/P6/client-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter AppGraphQLTests 2>&1 | tee tmp/search-engine-adapter/P6/graphql-suite.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P6 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P6/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "engineSearchNotes(query: String!, notebookId: String, tagFilter: \[String!\], limit: Int, offset: Int): EngineNoteSearchQueryPayload!" Sources/AppGraphQL/GraphQLContractProjector.swift
wc -l Sources/AppGraphQL/NoteGraphQLService.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift Sources/KaibaClient/KaibaOperations.swift Sources/KaibaClient/KaibaModels.swift
```

Expected evidence:

- `exit=0` for every run, including the full AppGraphQLTests and
  KaibaClientTests suites.
- The grep finds the exact SDL line.
- `NoteGraphQLService.swift` is still 956 lines.

## Done criteria

- [ ] The SDL, registries, dispatch and validators match the pinned
      contract.
- [ ] Error statuses are `feature-disabled` and `search-engine-unavailable`,
      with fixed diagnostics.
- [ ] The 3 KaibaClient operations and their models exist and are tested.
- [ ] Every existing GraphQL and KaibaClient suite passes.

## Progress Log

- 2026-10-04: Plan created.
