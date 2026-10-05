# P6 GraphQL graph-search routing, provenance field and KaibaClient

**Status**: Not Started
**planId**: P6-graphql-client-provenance
**Wave**: 3
**dependsOn**: P2-engine-seeded-retrieval
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F1 "Callers" table, F2 "GraphQL and KaibaClient (additive)"
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

GraphQL `searchNotes` with `includeLinked: true` must go through
`NoteService.retrieveNotes` (P2). Without `includeLinked`, it stays on
`searchNotes`. `NoteSearchResult` gains the additive non-null field
`provenance: NoteRetrievalProvenance!`. FTS results get a derived value.
KaibaClient selects and decodes the field.

Repository facts:

- `Sources/AppGraphQL/NoteGraphQLService.swift` (956 lines):
  - `public func searchNotes(query:tagFilter:classFilter:notebookId:sort:createdAfter:createdBefore:includeLinked:depth:limit:offset:) async -> GraphQLNoteQueryResult<[GraphQLNoteSearchResultDTO]>`
    (around line 210) wraps `noteResult { try service.searchNotes(...) }`;
  - `noteResult(_:)` (line 881) is the sync result wrapper;
  - `graphQLNoteListSort(_:)` parses `sort`.
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift:255` calls that
  service method. No change is needed there; verify with a read.
- `Sources/AppGraphQL/NoteGraphQLContracts.swift:GraphQLNoteSearchResultDTO`
  (around line 282).
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift:49`:
  `type NoteSearchResult { ... termCoverage: Float! }`.
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift:730`: the
  `"NoteSearchResult"` selection-field map. See `"EngineHitReason"` near
  line 412 as the pattern for a nested object type.
- `Sources/KaibaClient/KaibaModels.swift:KaibaNoteSearchResult` (line ~159,
  synthesized `Codable`).
- `Sources/KaibaClient/KaibaOperations.swift:searchNotes(...)` (line ~140)
  holds the selection text `isLinkedNeighbor termCoverage }`.
- `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift:835-849`
  holds the expected `searchNotes` document, which must be updated in
  lockstep with the client selection.
- `Tests/AppGraphQLTests/NoteGraphQLTests.swift:772` asserts the schema
  contains `isLinkedNeighbor: Boolean!, termCoverage: Float!`. Appending
  after `termCoverage` keeps that substring.

## Non-goals

- No change to `engineSearchNotes`, `relatedNotes` or the settings fields.
- No web change. `web/src` does not select `provenance`.
- No payload-level `retrieval` field.

## writePaths

- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLService+EngineSeededSearch.swift`
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/KaibaClient/KaibaModels.swift`
- `Sources/KaibaClient/KaibaOperations.swift`
- `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift`
- `Tests/AppGraphQLTests/EngineSeededSearchGraphQLTests.swift`
- `impl-plans/active/search-engine-fusion-p6-graphql-client-provenance.md`
- `tmp/search-engine-fusion/P6`

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/NoteModels.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`

## sharedPathNotes

- `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift`:
  intendedEdit: update only the expected `searchNotes` document (append
  `provenance { sources reasons }` after `termCoverage`). If a decode
  fixture needs it, add a `provenance` object to the search-result fixture
  near line 753. Change no other expectation.
- `Sources/AppGraphQL/NoteGraphQLService+EngineSeededSearch.swift`:
  intendedEdit: new file; create it only if `NoteGraphQLService.swift`
  would exceed about 975 lines. It holds the async `includeLinked` branch
  helper.
- `Tests/AppGraphQLTests/EngineSeededSearchGraphQLTests.swift`: intendedEdit: new test file.
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: intendedEdit: read-only; written by P2.
- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: read-only; written by P1.
- `Sources/AppCore/NoteModels.swift`: intendedEdit: read-only; `NoteSearchResult.provenance`, written by P1.
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift`: intendedEdit: read-only; confirm it calls `NoteGraphQLService.searchNotes`.
- `tmp/search-engine-fusion/P6`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P6`

## File-level changes

1. `NoteGraphQLService.searchNotes`:
   - when `includeLinked` is true, await
     `service.retrieveNotes(...)` with the same arguments and map
     `.results` through `GraphQLNoteSearchResultDTO.init`, with the same
     error mapping as `noteResult` (`graphQLNoteResult(for:)`);
   - otherwise keep the current body;
   - the file must stay under 1000 lines (currently 956). If the async
     branch would push it past about 975, move the helper into the
     declared `Sources/AppGraphQL/NoteGraphQLService+EngineSeededSearch.swift`
     and record that in the progress log.
2. `NoteGraphQLContracts.swift`:
   - add
     `public struct GraphQLNoteRetrievalProvenanceDTO: Codable, Equatable, Sendable { sources: [String]; reasons: [String] }`;
   - `GraphQLNoteSearchResultDTO.provenance` is
     `result.provenance` mapped to raw strings, or, when nil,
     `sources: [isLinkedNeighbor ? "graph-neighbor" : "full-text"]` with
     `reasons: []`.
3. `GraphQLNoteSchemaContract.swift`:
   - append `, provenance: NoteRetrievalProvenance!` to `NoteSearchResult`;
   - add `type NoteRetrievalProvenance { sources: [String!]!, reasons: [String!]! }`
     next to it.
4. `NoteGraphQLDocumentExecutorSupport.swift`:
   - in the `"NoteSearchResult"` map, add
     `"provenance": "NoteRetrievalProvenance"`;
   - add the `"NoteRetrievalProvenance": ["sources": nil, "reasons": nil]`
     entry.
5. KaibaClient:
   - add `public struct KaibaNoteRetrievalProvenance: Codable, Equatable, Sendable { sources, reasons }`
     and `public var provenance: KaibaNoteRetrievalProvenance?` on
     `KaibaNoteSearchResult` (optional, so older payloads decode);
   - append `provenance { sources reasons }` to the selection.

## Invariants

- `searchNotes` without `includeLinked` never calls the engine.
- Responses that do not select `provenance` are unchanged.
- `NoteGraphQLSchemaInventoryTests`, `GraphQLIntrospectionTests`,
  `NoteGraphQLTests`, `SearchEngineGraphQLTests` and
  `NoteGraphQLSearchPaginationTests` pass. The AppServer
  `GraphQLSchemaAuthorizationTests` pass (run in P10).

## Pitfalls

- Do not change `searchNotes` argument validation (`validatedLimit`,
  `validatedOffset`).
- The new type must be registered in both the schema contract and the
  selection-field map, or selecting it fails with an unknown-field error.
- Do not make the AppCore type `Codable`. Map it to the DTO.
- Version skew is accepted (design review, low): the client and server
  ship together.

## Tests (`EngineSeededSearchGraphQLTests`, XCTest)

Imitate the setup of `SearchEngineGraphQLTests` (executor with a service
whose slot has a `FakeSearchEngine`).

- `searchNotes(query, includeLinked: true)` with an engine scripted to an
  engine-only note -> that note is in `value`, and its selected
  `provenance.sources` contains `"search-engine"`.
- `searchNotes(query)` without `includeLinked` with an engine attached ->
  `recordedSearches` is empty, and the values equal those from a
  no-engine service.
- FTS results with `provenance` selected -> `sources == ["full-text"]`
  (or `["graph-neighbor"]` for neighbors) and `reasons == []`.
- An engine with `failure` and `includeLinked: true` -> `accepted: true`,
  and the values equal the no-engine result.
- The schema contract contains `type NoteRetrievalProvenance` and
  `provenance: NoteRetrievalProvenance!`.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P6
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P6/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "EngineSeededSearchGraphQLTests|NoteGraphQLSchemaInventoryTests|GraphQLIntrospectionTests|NoteGraphQLTests|SearchEngineGraphQLTests|NoteGraphQLSearchPaginationTests" 2>&1 | tee tmp/search-engine-fusion/P6/graphql.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "KaibaTypedOperationContractTests|KaibaSchemaTests|KaibaClientTests" 2>&1 | tee tmp/search-engine-fusion/P6/client.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P6/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppGraphQL/NoteGraphQLService.swift Sources/AppGraphQL/NoteGraphQLContracts.swift Sources/AppGraphQL/GraphQLNoteSchemaContract.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift Sources/KaibaClient/KaibaModels.swift Sources/KaibaClient/KaibaOperations.swift Tests/AppGraphQLTests/EngineSeededSearchGraphQLTests.swift Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift
git diff -- Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift
wc -l Sources/AppGraphQL/NoteGraphQLService.swift Sources/AppGraphQL/NoteGraphQLContracts.swift Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift Sources/KaibaClient/KaibaOperations.swift
```

Expected evidence:

- build `exit=0`.
- The graphql and client runs show `exit=0` with an XCTest
  `Executed N tests, 0 failures`, N > 0. If a suite is swift-testing only,
  record its `Test run with N tests passed` line, N > 0.
- The contract-test diff shows only the selection, plus the fixture if
  needed.
- All files are under 1000 lines.

## Done criteria

- [ ] `includeLinked: true` routes through `retrieveNotes`; other searches
      are unchanged.
- [ ] `provenance` is in the schema, the selection map, the DTO and the
      client.
- [ ] Tests pass with positive counts. Evidence is recorded.

## Progress Log

- 2026-10-05: Plan created.
