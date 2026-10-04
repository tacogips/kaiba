# P5 Engine query service: engineSearchNotes, relatedNotes, scope filter and store re-check

**Status**: Ready
**planId**: P5-engine-query-service
**Wave**: 2
**dependsOn**: P1-core-contract, P2-store-outbox
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE1 (`NoteService.searchEngine`), SE4, Invariants 1 and 3
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

This plan adds engine-backed reads to `NoteService`. Library and multi-user
access is applied twice:

1. as a `SearchEngineFilter`, built from the same `NoteSearchScope` that
   `searchNotes` builds;
2. as a store re-check of every hit, using the same SQL predicate helpers
   as `searchNotesInDatabase`.

Index staleness may shorten a result list. It must never leak a note.

Repository facts:

- `NoteService+Search.swift:searchNotes` builds `NoteSearchScope` inline.
- The predicate helpers live in `Sources/AppCore/NoteSearch.swift`:
  - `appendLibraryScopePredicate`
  - `appendOwnerScopePredicate`
  - `appendPendingNotebookIngestExclusionPredicate`
  - `appendCreatedAtPredicates` (the internal overload at line 778)
  - the long-term memory clause used when
    `scope.excludesLongTermMemory && scope.actingUserId == nil`
- `searchNotesInDatabase` (`NoteSearch.swift:~232-275`) shows the exact
  predicate composition to mirror.
- `requireNote` (`NoteService+LibraryEnforcement.swift:33`) enforces reach,
  ownership and ingest finalization for one note.
- `requireNotes(_:in:)` (`NoteService+Hydration.swift:66`) bulk-hydrates
  notes.
- `expandedTagFilterIds(names:in:)` is in `NoteTagHierarchy.swift`.
- `snippet(from:query:)` (`NoteSearch.swift:834`) returns the first 200
  characters when the query is empty.
- `noteSearchTexts(_:in:)` and `noteRetrievalText` are in
  `NoteRetrievalText.swift`.
- `NoteService` is a struct. `scoped(to:)` and `scoped(toLibrary:)` copy
  `self`, so a new stored property is inherited by scoped copies
  automatically.

## Non-goals

- No change to `searchNotes` behavior, ranking or results.
- No GraphQL, CLI or server wiring.
- No support for sort, classFilter, created ranges or includeLinked in
  engine search.
- No engine-side pending-ingest filter. That check is store-only.

## writePaths

- `Sources/AppCore/NoteService.swift`
- `Sources/AppCore/NoteService+Search.swift`
- `Sources/AppCore/NoteService+SearchEngine.swift`
- `Sources/AppCore/SearchEngineScope.swift`
- `Tests/AppCoreTests/SearchEngineQueryTests.swift`
- `Tests/AppCoreTests/SearchEngineAccessTests.swift`
- `impl-plans/active/search-engine-adapter-p5-engine-query-service.md`

New files: `Sources/AppCore/NoteService+SearchEngine.swift`, `Sources/AppCore/SearchEngineScope.swift`, `Tests/AppCoreTests/SearchEngineQueryTests.swift`, `Tests/AppCoreTests/SearchEngineAccessTests.swift`.

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/NoteSearch.swift`
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`
- `Sources/AppCore/NoteService+Hydration.swift`
- `Sources/AppCore/NoteRetrievalText.swift`
- `Sources/AppCore/NoteTagHierarchy.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`

## sharedPathNotes

- `Sources/AppCore/SearchEngine.swift`: read-only: P1 contract.
- `Sources/AppCore/NoteSearch.swift`: read-only: `NoteSearchScope`, the
  `append*Predicate` helpers, `snippet(from:query:)`, and
  `searchNotesInDatabase` as the predicate reference.
- `Sources/AppCore/NoteService+LibraryEnforcement.swift`: read-only:
  `requireNote` and `reachableLibraryIds`.
- `Sources/AppCore/NoteService+Hydration.swift`: read-only: `requireNotes`.
- `Sources/AppCore/NoteRetrievalText.swift`: read-only: `noteRetrievalText` and
  `noteSearchTexts`.
- `Sources/AppCore/NoteTagHierarchy.swift`: read-only:
  `expandedTagFilterIds(names:in:)`.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only: P1 fake.

Reading references (not path declarations): existing multi-user and library
test helpers in `Tests/AppCoreTests`. Read them to learn how scoped and
unauthenticated services, libraries and members are created, for example
`NoteServiceLibraryTests` or the multi-user tests.

## File-level changes

### `Sources/AppCore/NoteService.swift`

- Add one stored property next to `changeObserver`:
  `public var searchEngine: (any SearchEngine)? = nil`, with a one-line doc
  comment citing design SE1.
- No init change; the default value covers it.
- P2 already edited this file in wave 1. Fresh-read and hash it first.
- The file must stay at or under 943 lines.

### `Sources/AppCore/NoteService+Search.swift`

- Extract the inline `NoteSearchScope(...)` construction into an internal
  helper:
  `func makeNoteSearchScope(notebookId: NotebookID?, createdAfter: String? = nil, createdBefore: String? = nil, in database: SQLiteDatabase) throws -> NoteSearchScope`.
  It lives in the same extension, and its field values are identical to
  today's.
- `searchNotes` then calls it. Its behavior must be identical, and the
  existing comment about applying the scope in the query moves with the
  code.

### `Sources/AppCore/SearchEngineScope.swift` (new)

- `func searchEngineFilter(for scope: NoteSearchScope, tagIds: [TagID], excludedNoteIds: [NoteID]) -> SearchEngineFilter`.
  - `libraryIds = scope.reachableLibraryIds`
  - `ownerUserId = scope.actingUserId`
  - `notebookId = scope.notebookId`
  - `excludesLongTermMemory = scope.excludesLongTermMemory`
- `func scopedNoteIds(_ noteIds: [NoteID], scope: NoteSearchScope, in database: SQLiteDatabase) throws -> Set<NoteID>`
  runs one query:
  `SELECT n.note_id FROM notes n WHERE n.note_id IN (...)`, followed by,
  in this order:
  1. the notebook equality when `scope.notebookId` is set;
  2. `appendLibraryScopePredicate`;
  3. `appendOwnerScopePredicate`;
  4. `appendPendingNotebookIngestExclusionPredicate`;
  5. the long-term memory clause when
     `scope.excludesLongTermMemory && scope.actingUserId == nil`;
  6. `appendCreatedAtPredicates`.

  An empty input returns an empty set without a query.

### `Sources/AppCore/NoteService+SearchEngine.swift` (new)

The pinned public API: `isSearchEngineEnabled`, `engineSearchNotes` and
`relatedNotes`.

`engineSearchNotes`:

1. If `searchEngine` is nil, throw `SearchEngineError.notConfigured`.
2. Trim the query. If it is empty, throw
   `NoteServiceError.invalidInput("query must not be empty")`.
3. `limit <= 0` returns `[]`. Negative offsets clamp to 0. The GraphQL
   layer validates the range.
4. Store phase, in `driver.withDatabase`:
   - Build the scope with `makeNoteSearchScope(notebookId:in:)`.
   - `reachableLibraryIds == []` returns `[]`.
   - Expand the tag filter. A non-empty filter that expands to nothing
     returns `[]`, mirroring `searchNotesInDatabase`.
   - Build the filter.
5. Engine phase, outside any database closure:
   `engine.search(SearchEngineQuery(text: trimmed, filter:, from: 0, size: offset + limit + 20))`.
   Compute `offset + limit` with overflow protection, as
   `searchNotesInDatabase` does.
6. Re-check phase, in `driver.withDatabase`:
   - Run `scopedNoteIds` with the same scope.
   - Keep hits in engine order, de-duplicated.
   - Slice `[offset, offset + limit)`.
   - Hydrate with `requireNotes`.
   - The snippet is the trimmed highlight when it is non-empty. Otherwise
     it is `snippet(from: noteRetrievalText(...), query: trimmed)`.
   - The score is the engine score.

`relatedNotes`:

1. Throw `notConfigured` if there is no engine.
2. Load the source with `requireNote(noteId)`. Any `notFound` propagates.
3. `limit <= 0` returns `[]`.
4. `likeText` is `(source.title ?? "") + "\n" + noteRetrievalText(source)`,
   capped at 4000 characters.
5. Scope with `notebookId: nil`. An empty reachable list returns `[]`.
6. The filter's `excludedNoteIds` is `[noteId]`.
7. Call `engine.relatedNotes(size: limit + 20)`.
8. Re-check with `scopedNoteIds`, drop the source id again, and take the
   first `limit`.
9. The snippet is the highlight, or otherwise
   `snippet(from: retrievalText, query: "")`.

Doc comments cite design SE4.

## Pitfalls

- **No `await` inside a database closure.** Engine calls must not happen
  inside `driver.withDatabase`; split the code into three phases.
- **Empty library list.** `reachableLibraryIds == []` means "nothing
  reachable" and must return `[]` without an engine call. `nil` means
  unrestricted. Do not confuse them.
- **Parity with `searchNotes`.** The re-check must use the identical
  predicate set as `searchNotesInDatabase`, including pending ingest and
  long-term memory. Do not reuse `reachableNoteIds` from LibraryEnforcement:
  it omits pending-ingest exclusion.
- **Source note access.** `relatedNotes` must call `requireNote` before
  anything else. An unreachable source returns `notFound`, which is
  indistinguishable from a missing note.
- **Default path.** Do not change `searchNotes` output. The extraction is
  mechanical only.

## Tests

`SearchEngineQueryTests` (XCTest; `makeService`, `FakeSearchEngine`
assigned to `service.searchEngine`):

- Seed the fake only with `fake.apply([.upsert(...)])`, using
  `SearchIndexDocument` values built in the test from the created notes'
  ids, notebook, library and text. Alternatively, set `scriptedHits`.
- Do NOT use P4's `SearchIndexSynchronizer`: P4 runs concurrently in the
  same wave.

Cases:

- With `searchEngine == nil`, `engineSearchNotes` throws `.notConfigured`,
  `relatedNotes` throws `.notConfigured`, `isSearchEngineEnabled` is false,
  and `searchNotes` results equal the same call before this plan. Assert
  by snapshotting `searchNotes` output for a fixture both with and without
  an engine set: the outputs are identical.
- An empty or whitespace-only query throws `invalidInput`.
- Results keep engine order. The snippet equals the highlight when scripted
  hits carry one, and falls back to `snippet(from:query:)` otherwise.
- Pagination: 30 matching notes with limit 10 and offset 10 return hits
  11-20. The recorded engine query has `from 0` and `size 40`.
- A tag filter name expands to descendant tag ids in `filter.tagIds`. An
  unknown tag name returns `[]` with 0 engine calls.
- `relatedNotes` never contains the source, even when scripted hits include
  it. The recorded `likeText` starts with the source title, and its length
  is at most 4000.

`SearchEngineAccessTests` (XCTest; use the scripted hits that ignore the
filter, so the re-check alone must enforce access):

- An unauthenticated principal with library L1 public and L2
  `authRequired`: scripted hits from both return only L1 notes. The
  recorded filter has `libraryIds == [L1]` and
  `excludesLongTermMemory == true`.
- User A scoped, with a hit in user B's notebook: dropped. The filter has
  `ownerUserId == A`.
- A hit in a notebook with pending ingest is dropped for a caller without
  pending access.
- A hit in the long-term memory notebook is dropped for scoped and
  unauthenticated callers.
- A hit for a deleted note (an orphaned document) is dropped without
  error.
- A caller whose reachable libraries are `[]` gets `[]`, and the fake
  records 0 searches.
- `relatedNotes` on a note in a library the caller cannot reach throws
  `notFound`. On a reachable source, the scripted hits including
  unreachable notes are filtered out.
- A service from `scoped(to:)` still has `isSearchEngineEnabled == true`,
  because the property is inherited.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P5 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineQuery 2>&1 | tee tmp/search-engine-adapter/P5/query.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P5 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineAccess 2>&1 | tee tmp/search-engine-adapter/P5/access.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P5 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteSearch 2>&1 | tee tmp/search-engine-adapter/P5/note-search-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P5 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Library 2>&1 | tee tmp/search-engine-adapter/P5/library-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P5 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P5/lint.log; echo exit=${PIPESTATUS[0]}'
grep -n "public var searchEngine" Sources/AppCore/NoteService.swift
grep -n "makeNoteSearchScope" Sources/AppCore/NoteService+Search.swift Sources/AppCore/NoteService+SearchEngine.swift
wc -l Sources/AppCore/NoteService.swift Sources/AppCore/NoteService+SearchEngine.swift Sources/AppCore/SearchEngineScope.swift
```

Expected evidence:

- `exit=0` for every run.
- The existing `NoteSearch*` and Library suites still pass.
- `NoteService.swift` is at or under 943 lines.

## Done criteria

- [ ] `NoteService.searchEngine` exists, and scoped copies inherit it.
- [ ] `engineSearchNotes` and `relatedNotes` implement the three-phase flow,
      with the pinned errors and limits.
- [ ] The store re-check uses the same predicates as `searchNotesInDatabase`.
      Every access test passes with filter-ignoring scripted hits.
- [ ] `searchNotes` behavior is unchanged, and its regression suites pass.

## Progress Log

- 2026-10-04: Plan created.
