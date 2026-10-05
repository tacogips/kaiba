# P5 Agentic grounding with engine-seeded retrieval

**Status**: Not Started
**planId**: P5-agentic-grounding
**Wave**: 3
**dependsOn**: P2-engine-seeded-retrieval
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F1 "Agentic grounding", F2 rule 5 (reduction property), Invariants 1-2
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

When an engine is attached, `AIAgenticSearchService` grounding runs each
grep term through `retrieveNotes`. The full query includes linked notes;
the other terms do not. The per-term direct lists are fused with the
shared reranker at today's weights. Any engine failure falls back to
today's FTS grounding. With no engine, the existing sync
`groundingResults` keeps its exact output, but its RRF now uses
`NoteRetrievalReranker.fuse` (one fusion implementation).

Repository facts:

- `Sources/AppCore/AIAgenticSearch.swift` (261 lines):
  - `search(query:notebookId:limit:) async` calls
    `static func groundingResults(query:terms:notebookId:limit:service:) throws -> GroundingResults`
    (lines 142-190). It weights the full query 2 (with `includeLinked`,
    depth 1) and each term 1, sorts by score descending then note id, keeps
    the first-seen result per id, and puts graph neighbors into
    `relatedNotes`, excluding matches and capping at `limit`.
  - `grepTerms(from:)` and `grepContextMarkdown(query:noteMatches:relatedNotes:memoMatches:)`.
- `Tests/AppCoreTests/NoteRetrievalFusionTests.swift:testGroundingResultsRankMultiTermSupportFirstAndLabelRelatedNotes`
  calls the sync `groundingResults` and `grepContextMarkdown`. It must pass
  unchanged.
- `NoteService.isSearchEngineEnabled` and `retrieveNotes(...)` (P2).
- `NoteRetrievalReranker.fuse`, `NoteRetrievalCandidateList` and
  `NoteRetrievalSource.agentQuery` (P1).

## Non-goals

- No change to the prompt, `kaibaSearchCommandUsage`, `grepTerms`, the
  stopwords or the memo pass.
- No change to `NoteGraphQLService.agenticSearch` or `AICommand.swift`.

## writePaths

- `Sources/AppCore/AIAgenticSearch.swift`
- `Tests/AppCoreTests/AgenticGroundingEngineTests.swift`
- `impl-plans/active/search-engine-fusion-p5-agentic-grounding.md`
- `tmp/search-engine-fusion/P5`

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Tests/AppCoreTests/NoteRetrievalFusionTests.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`

## sharedPathNotes

- `Tests/AppCoreTests/AgenticGroundingEngineTests.swift`: intendedEdit: new test file.
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: intendedEdit: read-only; written by P2.
- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: read-only; written by P1.
- `Tests/AppCoreTests/NoteRetrievalFusionTests.swift`: intendedEdit: read-only and protected; the grounding test must pass unchanged.
- `tmp/search-engine-fusion/P5`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P5`

## File-level changes (`AIAgenticSearch.swift`, stays under 400 lines)

1. `groundingResults` (sync; signature unchanged): replace the
   `reciprocalRankFusion` call and its sort with
   `NoteRetrievalReranker.fuse`. Use one direct list per term, weight 2 for
   index 0 and 1 for the others, label nil, entries with empty provenance,
   and `limit`. Map back through `resultsById`. The rest of the logic is
   unchanged. The result must be identical to today's.
2. New
   `static func engineGroundingResults(query:terms:notebookId:limit:service:) async throws -> GroundingResults?`.
   It returns nil when any term's
   `retrieveNotes(query: term, notebookId:, includeLinked: index == 0, depth: 1, limit:)`
   has `usedSearchEngine == false`. Stop calling further terms once one
   returns false. Otherwise:
   - fuse the per-term direct lists. Weights are 2/1. The label is nil for
     index 0 and `.agentQuery` for the others. Each entry's provenance is
     the result's provenance;
   - build `noteMatches` from the first-seen result per id, with
     `provenance` replaced by the fused provenance;
   - build `relatedNotes` from the index-0 neighbors exactly as today.
3. `search(...)`:

   ```swift
   let grounding = service.isSearchEngineEnabled
     ? (try await engineGroundingResults(...) ?? groundingResults(...))
     : groundingResults(...)
   ```

4. `grepContextMarkdown`: for a match or related line whose result has
   non-nil `provenance`, append
   ` [sources: a, b; reasons: x, y]` with raw values joined by `", "`. Omit
   `; reasons: ...` when the reasons are empty. Lines with nil provenance
   are byte-identical to today.

## Invariants

- No engine: `search` builds exactly today's context document.
  `testGroundingResultsRankMultiTermSupportFirstAndLabelRelatedNotes`
  passes unchanged.
- An engine failure on any term produces exactly today's FTS grounding and
  context.
- Every engine-mode grounding pass makes at most `terms.count` (6 or fewer)
  engine requests.

## Pitfalls

- Floating-point equality: `fuse` must produce the same order as today.
  If any existing grounding assertion fails, fix the call site (weights,
  list order, 1-based positions), not the test.
- Do not put the provenance suffix on FTS-only lines. Today's snapshot
  text must not change.
- Do not run engine and FTS grounding both "just in case". Pick one path
  per pass.

## Tests (`AgenticGroundingEngineTests`, XCTest, `NoteTestCase`)

- No engine: `groundingResults` and `grepContextMarkdown` for "pepper
  sauce" equal the values computed with the pre-change algorithm (the
  test re-implements today's RRF ordering inline for comparison).
- Engine attached with `scriptedHits` of an engine-only note E (body lacks
  every term) -> `engineGroundingResults` includes E in `noteMatches` with
  sources containing `"search-engine"`. `recordedSearches.count ==
  terms.count`. The context line for E ends with `[sources: ...]`.
- A note matched only by a non-first term carries `"agent-query"`.
- Engine `failure = .unavailable("x")` -> `engineGroundingResults` returns
  nil after one engine request, and `search`'s grounding equals the FTS
  grounding. Assert through a fake `AgentInvoking` that captures
  `contextMarkdown` and compares it with the no-engine run.
- The full-query neighbor of E appears in `relatedNotes`, not in
  `noteMatches`.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P5
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P5/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgenticGroundingEngineTests|NoteRetrievalFusionTests" 2>&1 | tee tmp/search-engine-fusion/P5/grounding.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P5/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppCore/AIAgenticSearch.swift Tests/AppCoreTests/AgenticGroundingEngineTests.swift
git diff --stat -- Tests/AppCoreTests/NoteRetrievalFusionTests.swift
wc -l Sources/AppCore/AIAgenticSearch.swift
```

Expected evidence:

- build `exit=0`.
- The grounding run shows `exit=0` and `Executed N tests, 0 failures` with
  N > 0, including the existing grounding test and at least 5 new tests.
- `NoteRetrievalFusionTests` is unmodified (empty diff stat).
- The file is under 400 lines.

## Done criteria

- [ ] Engine-mode grounding uses `retrieveNotes` plus `fuse` with the
      all-or-nothing fallback.
- [ ] No-engine grounding is identical and uses `fuse`.
- [ ] The provenance suffix appears only in engine mode.
- [ ] Tests pass with positive counts. Evidence is recorded.

## Progress Log

- 2026-10-05: Plan created.
