# P2 Engine-seeded retrieval (`retrieveNotes`)

**Status**: Completed. Accepted in session-268 (test-integrity, adversarial and combined-tree integration review, comm-004081). The P10 combined-tree gates passed (`impl-plans/completed/search-engine-fusion.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P2-engine-seeded-retrieval
**Wave**: 2
**dependsOn**: P1-fusion-contract
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F1 (Entry point, Algorithm, Health and per-call cost), Invariants 1-3
**Index**: `impl-plans/completed/search-engine-fusion.md`

## Intent and context

This plan adds the single async entry point that graph search, the agent
tool and agentic grounding use. When an engine is attached, it fuses
re-checked engine hits with today's FTS list, seeds the existing PPR graph
expansion from the fused hits, and attaches provenance. With no engine, or
on any engine error, it returns exactly `searchNotes(...)`.

Repository facts:

- `Sources/AppCore/NoteService+Search.swift:searchNotes(...)` is sync and
  wraps `searchNotesInDatabase` in `driver.withDatabase`.
  `makeNoteSearchScope(notebookId:createdAfter:createdBefore:in:)` builds
  the scope.
- `Sources/AppCore/NoteSearch.swift`:
  - `searchNotesInDatabase(query:tagFilter:classFilter:scope:sort:graphOptions:limit:offset:in:)`;
  - `appendLinkedNeighborResults(to:query:tagFilterIds:classFilter:scope:sort:depth:limit:in:)`,
    internal after P1, which returns `direct + neighbors.prefix(limit - direct.count)`;
  - `appendTagPredicates(alias:tagFilterIds:classFilter:predicates:bindings:)`;
  - `snippet(from:query:)`.
- `expandedTagFilterIds(names:in:)` is used by `searchNotesInDatabase` for
  tag filters. `resolveTagIds(named:in:)` returns `[TagID]?` and is used by
  `engineSearchNotesPage` for `hierarchyTagIds`.
- `Sources/AppCore/NoteService+SearchEngineOntology.swift:ontologyExpansionTagIds(query:in:)`.
- `Sources/AppCore/SearchEngineScope.swift`:
  `searchEngineFilter(for:tagIds:excludedNoteIds:hierarchyTagIds:tagClassFilters:)`
  and `scopedNoteIds(_:scope:in:)`, the SE4 predicates to imitate.
- `Sources/AppCore/NoteService+SearchEngine.swift:engineSearchNotesPage`
  is the pattern for the prepare / engine-await / re-check split. Note its
  overflow-safe size arithmetic.
- `noteRetrievalText(bodyMarkdown:searchText:)`, `noteSearchTexts(_:in:)`,
  `requireNotes(_:in:)` (hydration only; it does not check reach) and
  `indexableSearchTerms(from:)`.
- The fake engine is `Tests/AppCoreTests/FakeSearchEngine.swift`. Its knobs
  are `scriptedHits`, `failure` and `recordedSearches`, and it ignores
  filters.

## Non-goals

- No change to `searchNotes`, `searchNotesInDatabase`,
  `engineSearchNotes*`, `relatedNotes`, GraphQL, the agent tool or
  agentic grounding (those are P4, P5 and P6).
- No health probe and no circuit breaker.
- No change to `FakeSearchEngine.swift`.

## writePaths

- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Tests/AppCoreTests/EngineSeededRetrievalTests.swift`
- `impl-plans/completed/search-engine-fusion-p2-engine-seeded-retrieval.md`
- `tmp/search-engine-fusion/P2`

## sharedPaths (read-only)

- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/NoteSearch.swift`
- `Sources/AppCore/NoteService+Search.swift`
- `Sources/AppCore/NoteService+SearchEngine.swift`
- `Sources/AppCore/NoteService+SearchEngineOntology.swift`
- `Sources/AppCore/SearchEngineScope.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`

## sharedPathNotes

- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: intendedEdit: new file with `retrieveNotes` and `eligibleSearchCandidateIds`.
- `Tests/AppCoreTests/EngineSeededRetrievalTests.swift`: intendedEdit: new test file.
- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: read-only; written by P1.
- `Sources/AppCore/NoteSearch.swift`: intendedEdit: read-only; P1 owns it; call `appendLinkedNeighborResults` and `searchNotesInDatabase` without modifying them.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: intendedEdit: read-only; use the knobs `scriptedHits`, `failure` and `recordedSearches`.
- `tmp/search-engine-fusion/P2`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P2`

## File-level changes (`NoteService+EngineSeededRetrieval.swift`, under 400 lines)

Pinned signature (P4, P5 and P6 call it):

```swift
public extension NoteService {
  func retrieveNotes(
    query: String, tagFilter: [String] = [], classFilter: [String] = [],
    notebookId: NotebookID? = nil, sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil, createdBefore: String? = nil,
    includeLinked: Bool = false, depth: Int = 1,
    limit: Int = 20, offset: Int = 0
  ) async throws -> NoteRetrievalOutcome
}
```

Algorithm (design F1 steps 1-7):

1. **FTS fallback** (`fts()`): call `searchNotes(...)` with the identical
   arguments and return `NoteRetrievalOutcome(results:, usedSearchEngine: false)`.
   Take this path when any of these holds:
   - `searchEngine == nil`;
   - the trimmed query is empty;
   - `limit <= 0`;
   - `window = offset + limit` (overflow-guarded) is greater than
     `NoteRetrievalFusionPolicy.maximumFusedWindow`.
2. **Prepare** in one `driver.withDatabase`:
   - build the scope;
   - return the FTS fallback when `scope.reachableLibraryIds == []`, or
     when `tagFilter` is non-empty and `resolveTagIds(named:)` is nil or
     empty;
   - otherwise collect `hierarchyTagIds` and
     `ontologyExpansionTagIds(query: trimmed)`.

   Capture the engine reference once (`let engine = searchEngine`) before
   leaving the closure.
3. **Engine call**, outside any database closure:
   `try await engine.search(SearchEngineQuery(text: trimmed, filter: searchEngineFilter(for: scope, tagIds: [], excludedNoteIds: [], hierarchyTagIds:), from: 0, size: min(window + 20, maximumEngineCandidates), expansionTagIds:))`.
   Catch every error (`catch {}`, not only `SearchEngineError`) and return
   the FTS fallback.
4. **One `driver.withDatabase`** for re-check, FTS, fusion and hydration:
   - Engine ids: keep the first occurrence of each id. Re-check them with a
     new internal helper,
     `eligibleSearchCandidateIds(_ ids: [NoteID], scope:, tagFilterIds: [TagID], classFilter: [String], in:) throws -> Set<NoteID>`.
     It runs one SQL query with the same predicates as `scopedNoteIds`
     (notebook, library, owner, pending ingest, long-term memory,
     created-at), plus `appendTagPredicates` with
     `expandedTagFilterIds(names: tagFilter)` and `classFilter`. Keep the
     engine order of the survivors.
   - FTS list: `searchNotesInDatabase(query:tagFilter:classFilter:scope:sort:graphOptions: NoteSearchGraphOptions(includeLinked: false, depth: depth), limit: window, offset: 0, in:)`.
   - Fuse: `NoteRetrievalReranker.fuse([fullText list (label .fullText, weight 1, direct), searchEngine list (label .searchEngine, weight 1, direct, entries carrying the hit reason kinds)], limit: window)`.
   - Build direct `NoteSearchResult`s in fused order:
     - FTS notes reuse their FTS result. A non-empty trimmed engine
       highlight replaces the snippet.
     - Engine-only notes are hydrated with `requireNotes`. The snippet is
       the highlight, or `snippet(from: retrievalText, query:)`.
       `termCoverage` is the share of `indexableSearchTerms(query)` found
       case-insensitively in `(title ?? "") + " " + retrievalText`, or 0
       when there are no terms.
     - `rank` is the fused score, and `provenance` is the fused provenance.
   - When `includeLinked` is true: call
     `appendLinkedNeighborResults(to: directResults, query:, tagFilterIds: expanded, classFilter:, scope:, sort:, depth:, limit: window, in:)`.
     Take the `isLinkedNeighbor` results as a neighbor list, then call
     `fuse` again with the two direct lists plus that neighbor list
     (label `.graphNeighbor`, weight 1) and `limit: window`. The neighbor
     results keep their PPR `rank` and get provenance `[graph-neighbor]`.
   - Return `Array(results.dropFirst(offset).prefix(limit))` with
     `usedSearchEngine: true`.

## Invariants

- No engine, an engine error, or any short-cut condition: the outcome's
  `results` equal `searchNotes(...)` exactly (`==`, including `rank`,
  snippets and `provenance == nil`).
- No database transaction or `withDatabase` closure is held across the
  `await`.
- The reranker input contains only ids from the FTS SQL (already scoped)
  or from engine hits that survived `eligibleSearchCandidateIds`.
- The engine request size is never above 200.

## Pitfalls

- Do not fall back on a partial basis. If the engine throws, run the full
  FTS fallback; do not reuse anything from the failed attempt.
- `searchEngine` is backed by the shared slot and may change concurrently.
  Read it once.
- `classFilter` must not be sent to the engine. D2 class filters have
  different semantics.
- Deleted notes: an engine hit whose note is gone must be dropped by the
  re-check. Do not call `requireNotes` on unchecked ids, because it throws
  `notFound` for a missing note.
- Keep `rank` for FTS-only fallback results untouched. Only the fused path
  rewrites `rank`.
- Do not modify `NoteSearch.swift`. If something there seems needed,
  record it in the progress log for P10.

## Tests (`EngineSeededRetrievalTests`, XCTest, subclass `NoteTestCase`)

- No engine: for queries with `includeLinked` true and false, and with tag,
  class, created-after and notebook filters -> `retrieveNotes(...).results == searchNotes(...)`
  and `usedSearchEngine == false`.
- Engine `failure = .unavailable("x")` -> results equal `searchNotes(...)`,
  `usedSearchEngine == false`.
- Empty query, `limit: 0`, and `offset: 990, limit: 20` -> the engine's
  `recordedSearches` is empty and the results equal `searchNotes`.
- An engine-only hit A (body lacks the query word) is linked to note B.
  With `includeLinked: true` -> A is a direct result with provenance
  `[search-engine]`, and B appears with `isLinkedNeighbor == true` and
  provenance `[graph-neighbor]`.
- A note in both lists -> provenance `[search-engine, full-text]`. The
  snippet is the engine highlight when one is given, else the FTS snippet.
- Re-check (the fake ignores filters): hits in an unreachable library,
  another owner's notebook, the long-term-memory notebook for a scoped
  user, a pending ingest, outside the tag filter, failing a class filter,
  outside a created-at range, or deleted -> all absent from the results.
- The engine query size is `min(offset + limit + 20, 200)`. Check `size`
  in `recordedSearches` for `(limit 10, offset 0)` -> 30, and for
  `(limit 200, offset 100)` -> 200.
- `reachableLibraryIds == []` -> no engine call.
- An engine-only hit with reasons `[tagMatch]` -> provenance reasons
  `[tagMatch]`, `termCoverage` computed by the D4 rule.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P2
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P2/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter EngineSeededRetrievalTests 2>&1 | tee tmp/search-engine-fusion/P2/retrieval.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "NoteRetrievalFusionTests|SearchEngineAccessTests|SearchEngineQueryTests|NoteServiceTests" 2>&1 | tee tmp/search-engine-fusion/P2/regression.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P2/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppCore/NoteService+EngineSeededRetrieval.swift Tests/AppCoreTests/EngineSeededRetrievalTests.swift
grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+EngineSeededRetrieval.swift
wc -l Sources/AppCore/NoteService+EngineSeededRetrieval.swift
```

Expected evidence:

- build `exit=0`.
- The retrieval run shows `exit=0` and `Executed N tests, 0 failures` with
  N >= 9.
- The regression run shows `exit=0` with N > 0.
- Strict swiftlint is clean on the touched files.
- The boundary grep prints nothing.
- The new file is under 400 lines.

## Done criteria

- [x] `retrieveNotes` exists with the pinned signature and F1 semantics.
- [x] The no-engine and error paths are proven equal to `searchNotes`.
- [x] Re-check, PPR seeding, provenance and size caps are tested.
- [x] Verification evidence is recorded with log paths and exit codes.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Initial verification attempt after implementing `retrieveNotes` and `eligibleSearchCandidateIds` stopped during compilation in concurrent P3 files `Sources/AppCore/MeilisearchSearchEngine.swift` and `Sources/AppCore/MeilisearchRequestBodies.swift`. The initial aggregate lint exited 0 with 12 P3 warnings. These interim failures were resolved after P3 edits landed; final-source results are recorded below. Initial logs: `build.log`, `retrieval.log`, `regression.log`, and `lint.log` under `tmp/search-engine-fusion/P2`.
- 2026-10-05: Before the shared P3 compile fix, P2-local strict SwiftLint passed using `tmp/search-engine-fusion/P2/changed-swift-files.nul`; retrieval source was 287 lines and the agent-boundary grep was empty. Logs: `swiftlint-strict.log`, `boundary-and-lines.log`, and `parse.log` under `tmp/search-engine-fusion/P2`. Final-source checks are recorded in the next progress entry.
- 2026-10-05: Interim passing evidence before the final pending-ingest test was added: build-attempt-3, retrieval-attempt-4 (12 tests), regression-attempt-2 (63 tests), swiftlint-strict-final, lint-final, boundary-and-lines-final, and parse-final. Initial P3 compile failures are preserved in `build.log`, `retrieval.log`, and `regression.log`. `retrieval-attempt-2.log` records 12 tests with one fixture-only failure (`status` class not defined); after adding the class, `retrieval-attempt-3.log` passed all 12 with compiler warnings and `retrieval-attempt-4.log` passed cleanly after changing `var` to `let`.
- 2026-10-05: Final P2 verification includes the pending-ingest re-check test. `mise run build` exited 0 (`tmp/search-engine-fusion/P2/build-attempt-5.log`); `swift test --filter EngineSeededRetrievalTests` exited 0 with 13 tests and 0 failures (`tmp/search-engine-fusion/P2/retrieval-attempt-6.log`); regression filter `NoteRetrievalFusionTests|SearchEngineAccessTests|SearchEngineQueryTests|NoteServiceTests` exited 0 with 63 tests and 0 failures (`tmp/search-engine-fusion/P2/regression-attempt-3.log`). Changed-file strict SwiftLint exited 0 (`tmp/search-engine-fusion/P2/swiftlint-strict-final-2.log`). Repository-wide `mise run lint` exited 0 with three existing warnings in untouched `Sources/AppCore/NoteService.swift`, `Sources/AppCore/ResendGatewayCLIMailSender.swift`, and `Tests/AppCoreTests/AITranslationTests.swift` (`tmp/search-engine-fusion/P2/lint-final-2.log`). Boundary grep remains empty and production retrieval file is 287 lines (`boundary-and-lines-final.log`); parser check exited 0 (`parse-final.log`). P4/P5/P6 caller wiring and independent review remain downstream.
- 2026-10-05: Addressed test-integrity finding `P2-TI-001` in `Tests/AppCoreTests/EngineSeededRetrievalTests.swift` only. Added a same-class sibling plus independent tag-only and class-only calls with exact survivor assertions; retained the combined case and asserted engine use on the created-at case. Added default-user memory-owner and nil-user unauthenticated calls with hits `[memory, ownerNote]`; both preserve `ownerNote`, drop the long-term-memory note and assert `usedSearchEngine == true`. Added/confirmed `usedSearchEngine == true` on every engine-path result in the suite. No production code changed and no existing assertion was removed. The fresh retrieval run passed 13/13 (`retrieval-attempt-7.log`, exit 0); regression passed 63/63 (`regression-attempt-4.log`, exit 0); strict lint passed on the unchanged two-file manifest (`swiftlint-strict-final-4.log`, exit 0). The nil-user test confirms the engine path is reachable and exercises the nil-acting-user LTM exclusion branch.
