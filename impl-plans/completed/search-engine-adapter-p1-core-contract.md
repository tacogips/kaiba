# P1 Core contract: SearchEngine protocol, value types, configuration section, test fake

**Status**: Completed. Accepted in session-263 (test-integrity and adversarial review); code in b466ced. The session-264 integration review accepted it on the combined tree (comm-003910; `tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P1-core-contract
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE1, SE2
**Index**: `impl-plans/completed/search-engine-adapter.md` (pinned contracts and shared execution rules are binding)

## Intent and context

This plan creates the engine-agnostic contract that every later plan
compiles against:

- the `SearchEngine` protocol and its value types;
- the error enum;
- the optional `searchEngine` configuration section;
- an in-memory `FakeSearchEngine` for AppCore tests.

The plan adds no behavior: nothing calls the protocol yet, so the
unconfigured behavior stays byte-for-byte the same.

## Non-goals

- No factory and no validation of URLs or credentials. Both belong to P3.
- No `NoteService` property. P5 adds it.
- No Elasticsearch code, no outbox, no GraphQL.
- No change to `KaibaConfigurationLoader`.

## writePaths

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/KaibaConfiguration.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`
- `Tests/AppCoreTests/SearchEngineContractTests.swift`
- `Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift`
- `impl-plans/completed/search-engine-adapter-p1-core-contract.md`

New files: `Sources/AppCore/SearchEngine.swift`, `Tests/AppCoreTests/FakeSearchEngine.swift`, `Tests/AppCoreTests/SearchEngineContractTests.swift`, `Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/NoteModels.swift`

## sharedPathNotes

- `Sources/AppCore/NoteModels.swift`: read-only: `Note` and the identifier types
  (`NoteID`, `NotebookID`, `LibraryID`, `UserID`, `TagID`).

## File-level changes

### `Sources/AppCore/SearchEngine.swift` (new)

- Declare exactly the protocol, value types, `SearchEngineError` and the
  protocol extension pinned in the index section "AppCore protocol and
  types".
- Every type is `public` and has a `public init` that takes every stored
  property, in the pinned order.
- `SearchIndexOperation` gets `public var noteId: NoteID`.
- `SearchEngineError.description` produces fixed strings:
  - `.notConfigured`: "search engine is not configured"
  - `.unavailable(detail)`: "search engine unavailable: <detail>"
  - `.rejected(status, reason)`: "search engine rejected the request (HTTP <status>): <reason>"
  - `.invalidResponse(detail)`: "search engine returned an invalid response: <detail>"
- Doc comment: one short paragraph citing
  `design-docs/specs/search-engine-adapter.md` and stating that callers
  depend only on this protocol.
- Imitate the doc-comment density of
  `Sources/AppCore/KaibaConfiguration.swift:KaibaUserAgentConfiguration`.

### `Sources/AppCore/KaibaConfiguration.swift`

- Add `public var searchEngine: KaibaSearchEngineConfiguration?` to
  `KaibaConfiguration`.
- Add `searchEngine: KaibaSearchEngineConfiguration? = nil` as the last
  parameter of the public init, so existing call sites compile unchanged.
- Add `case searchEngine` to `CodingKeys`. Decode it with `decodeIfPresent`
  in `init(from:)`. Encoding stays synthesized through `CodingKeys`.
- Add `public struct KaibaSearchEngineConfiguration: Codable, Equatable, Sendable`
  with the pinned flat fields, a public init with defaults (nil for every
  optional), and the computed `isEnabled` and `resolvedIndexPrefix`.
- Decoding is plain synthesized Codable. Do NOT validate `kind` here: an
  unknown kind must decode successfully, and the P3 factory rejects it with
  a clear error.
- Add a doc comment noting that credential fields hold environment-variable
  names only, never values (mirror the `KaibaOCRConfiguration` comment).

### `Tests/AppCoreTests/FakeSearchEngine.swift` (new, test support used by P4, P5, P7)

- Declare `final class FakeSearchEngine: SearchEngine, @unchecked Sendable`.
  It guards all state with an `NSLock`.
- Init: `init(indexIdentity: String = "fake:v1")`.
- Observable state, read through lock-guarded accessors:
  - `documents: [NoteID: SearchIndexDocument]`
  - `appliedBatches: [[SearchIndexOperation]]`
  - `recordedSearches: [SearchEngineQuery]`
  - `recordedRelated: [SearchEngineRelatedQuery]`
  - `ensureIndexCount: Int`
  - `healthCalls: Int`
- Knobs:
  - `failure: SearchEngineError?`: when set, every method throws it.
  - `failingNoteIds: Set<NoteID>`: `apply` reports `.failed("fake failure")`
    for these and leaves `documents` untouched for them.
  - `scriptedHits: [SearchEngineHit]?`: when set, `search` and
    `relatedNotes` return it verbatim and ignore the filter. Access tests
    use this to prove the store re-check.
  - `onApply: (@Sendable ([SearchIndexOperation]) -> Void)?`: when set,
    `apply` calls it with the batch, outside the lock, before recording the
    batch. P4 uses it to simulate a write racing a push.
- `apply` semantics:
  - upsert stores the document;
  - delete removes it and succeeds even when it was absent;
  - one result per operation, in order.
- `search` semantics, when no hits are scripted:
  - Case-insensitive substring match of the trimmed query over
    `title`, `body`, `tagNames` joined with spaces, and `context`.
  - Then apply every filter field exactly:
    - `libraryIds`: nil means any; an empty list means none.
    - `ownerUserId`, `notebookId`: equality.
    - `tagIds`: any-of.
    - `excludesLongTermMemory`, `excludedNoteIds`.
  - Sort by `noteId`, apply `from`/`size`, and return
    `score = 1` and `highlight = nil`.
- `relatedNotes` semantics: documents sharing any whitespace-separated token
  (lowercased, at least 2 characters) with `likeText`, with the same filter
  rules, sorted by `noteId`, limited to `size`.
- `health` returns `SearchEngineHealth(isAvailable: true, detail: "fake")`,
  unless `failure` is set.

## Pitfalls

- Swift 6 strict concurrency: every new type must be `Sendable`. The fake
  must be `@unchecked Sendable` and keep all its state behind its lock. Do
  not use actors for the fake, because the protocol methods are
  non-isolated.
- Keep the field order and names exactly as pinned. P3, P4, P5 and P6
  compile against them in parallel.
- Do not add an `enabled` gate or an `isEnabled` check anywhere except the
  computed property.
- `KaibaConfiguration` must still decode every existing config file. A
  missing `searchEngine` key must yield nil.

## Tests

`SearchEngineContractTests` (XCTest):

- `apply([.upsert(d1), .delete(n2)])` on the fake gives two results in
  order, `documents` contains d1, and deleting a missing id succeeds.
- `upsert(d1)` calls `apply` with exactly one batch of one operation, and so
  does `delete(noteId:)`.
- A fake with filter `libraryIds: []` returns nothing. A fake with
  `libraryIds: nil` returns matching documents from every library. An
  `excludedNoteIds` id never appears.
- `scriptedHits` are returned verbatim even when the filter would exclude
  them.
- `SearchEngineError` descriptions equal the pinned strings, and none
  contains "Authorization" or "@".

`KaibaSearchEngineConfigurationDecodingTests` (XCTest):

- A config JSON with no `searchEngine` key gives `configuration.searchEngine == nil`.
- `{"searchEngine":{"kind":"elasticsearch","url":"http://127.0.0.1:9200"}}`
  decodes. `isEnabled` is true, and `resolvedIndexPrefix` is "kaiba".
- `"enabled": false` gives `isEnabled == false`.
- `"kind": "opensearch"` still decodes, because validation is P3's job.
- An encode/decode round trip preserves every field.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P1 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineContract 2>&1 | tee tmp/search-engine-adapter/P1/contract.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P1 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaSearchEngineConfigurationDecoding 2>&1 | tee tmp/search-engine-adapter/P1/config.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P1 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaConfiguration 2>&1 | tee tmp/search-engine-adapter/P1/existing-config.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P1 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P1/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "public protocol SearchEngine" Sources/AppCore/SearchEngine.swift
grep -n "searchEngine" Sources/AppCore/KaibaConfiguration.swift
wc -l Sources/AppCore/SearchEngine.swift Sources/AppCore/KaibaConfiguration.swift
```

Expected evidence:

- `exit=0` for each `swift test` run.
- The new tests run, with more than 0 tests executed.
- The existing configuration tests still pass.
- Lint exits 0.
- Both files are under 1000 lines.

## Done criteria

- [x] The pinned protocol, types, error and protocol extension exist, with
      the exact names.
- [x] `KaibaConfiguration.searchEngine` decodes, defaults to nil, and
      existing init call sites compile unchanged.
- [x] `FakeSearchEngine` implements the specified semantics and knobs.
- [x] All verification commands show `exit=0`, and the evidence paths are
      recorded below.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented the pinned AppCore protocol and value types, optional
  configuration decoding, lock-protected fake, and focused tests. Verification
  passed: `mise run build` (`tmp/search-engine-adapter/P1/build.log`),
  `SearchEngineContract` (5 tests; `contract-current-tree.log`),
  `KaibaSearchEngineConfigurationDecoding` (3 tests; `config-current-tree.log`),
  existing `KaibaConfiguration` (8 tests; `existing-config-final.log`), strict
  changed-file SwiftLint (`swiftlint-changed-final.log`), and repository
  `mise run lint` (`lint.log`, exit 0). Protocol/config shape and line counts
  are recorded in `contract-shape-final.log` (197 and 520 lines). An earlier
  existing-config compile attempt caught a concurrent P2 test edit; the owner
  corrected that shared file and the final current-tree rerun passed.
