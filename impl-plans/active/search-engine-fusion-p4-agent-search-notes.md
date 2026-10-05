# P4 Agent `search_notes` through engine-seeded retrieval

**Status**: Not Started
**planId**: P4-agent-search-notes
**Wave**: 3
**dependsOn**: P2-engine-seeded-retrieval
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F1 "Agent `search_notes` output", "Changed base rules" (D4 routing replaced)
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

The agent `search_notes` tool must use the engine for both
`include_linked` values, through `NoteService.retrieveNotes` (P2), so the
agent sees the same ranking as user-facing graph search. With no engine,
or after an engine error, the tool output must be byte-identical to
today's FTS output.

Repository facts:

- `Sources/AppCore/KaibaAgentToolbox.swift` (544 lines):
  - `execute(_:)` routes `"search_notes"` to
    `searchNotesRouted(_:) async`;
  - `run(_:)` keeps a sync `searchNotes(_:)` (FTS, output keys `query`,
    `results[{note_id, notebook_id, title, snippet, updated_at, term_coverage, is_linked_neighbor, tags}]`,
    `retrieval: "full-text"`);
  - `searchNotesRouted` today uses `engineSearchNotes` only when
    `!includeLinked` and computes engine coverage itself;
  - `SearchNotesToolParameters` parses the input (limit 1...50, default
    10).
- `retrieveNotes(query:tagFilter:classFilter:notebookId:sort:createdAfter:createdBefore:includeLinked:depth:limit:offset:) async throws -> NoteRetrievalOutcome`
  (P2). Its engine-mode results carry `provenance`, the fused snippet and
  `termCoverage` (the D4 rule for engine-only notes).
- `NoteRetrievalProvenance.sources` and `.reasons` (P1) have raw string
  values (`NoteRetrievalSource.rawValue`, `SearchEngineHitReasonKind.rawValue`).
- `Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift` holds the D4
  tests. Only `testIncludeLinkedKeepsFullTextRouting` encodes the replaced
  rule.

## Non-goals

- No change to `KaibaAgentToolSchema.swift`; the tool description is
  unchanged.
- No change to other tools, to `run`'s FTS output, or to `AIAgenticSearch.swift`.

## writePaths

- `Sources/AppCore/KaibaAgentToolbox.swift`
- `Tests/AppCoreTests/AgentSearchNotesFusionTests.swift`
- `Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift`
- `impl-plans/active/search-engine-fusion-p4-agent-search-notes.md`
- `tmp/search-engine-fusion/P4`

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/KaibaAgentToolSchema.swift`
- `Tests/AppCoreTests/FakeSearchEngine.swift`

## sharedPathNotes

- `Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift`: intendedEdit:
  remove only `testIncludeLinkedKeepsFullTextRouting`, which asserts the
  D4 rule that the accepted design replaces (design "Changed base rules").
  `AgentSearchNotesFusionTests` replaces it. Keep every other test
  byte-identical.
- `Tests/AppCoreTests/AgentSearchNotesFusionTests.swift`: intendedEdit: new test file.
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: intendedEdit: read-only; written by P2 (`retrieveNotes`).
- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: read-only; written by P1 (provenance types).
- `Sources/AppCore/KaibaAgentToolSchema.swift`: intendedEdit: read-only; the tool schema text must not change.
- `tmp/search-engine-fusion/P4`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P4`

## File-level changes (`KaibaAgentToolbox.swift`, stays under 600 lines)

1. Rewrite `searchNotesRouted`:
   - parse `SearchNotesToolParameters` as today;
   - call
     `service.retrieveNotes(query:tagFilter:notebookId:includeLinked:depth: 1, limit:, offset: 0)`;
   - if `usedSearchEngine == false`, return the existing FTS JSON exactly
     as `searchNotes(_:)` builds it (same key order, `retrieval:
     "full-text"`, no `provenance`). Extract the per-result JSON builder
     into one private helper that both `searchNotes(_:)` and
     `searchNotesRouted` use, so the outputs cannot drift.
2. When the engine was used:
   - build the same keys from each result;
   - set `"retrieval": "search-engine"`;
   - add per result `"provenance": {"sources": [raw strings], "reasons": [raw strings]}`.
3. Delete the old engine-specific coverage computation and the
   `engineSearchNotes` call. The coverage now comes from
   `result.termCoverage`.
4. Errors: `retrieveNotes` already falls back on engine errors. Any other
   thrown error propagates to `execute`'s error wrapping, as today.

## Invariants

- Without an engine, the JSON for any input equals today's output.
  `testNoEngineUsesFullTextAndPreservesSearchResults` passes unchanged.
- `testEngineUsesRetrievalTextForCoverageAndPreservesOutputKeys` (coverage
  0.5, snippet "engine snippet"), `testSearchEngineErrorFallsBackToFullText`,
  `testEngineResultsAreRecheckedAgainstStoreReachability` and
  `testInvalidLimitRetainsToolValidationError` pass unchanged.
- `KaibaAgentToolboxTests` passes unchanged.

## Pitfalls

- Do not add `provenance` when the engine was not used. This is the
  strict byte-identity rule.
- Do not change the tool schema text or the parameter limits.
- JSON key order follows the existing `JSONValue.object` construction. Use
  the shared helper rather than a parallel dictionary.
- Use `depth: 1`, as today.

## Tests (`AgentSearchNotesFusionTests`, XCTest, `NoteTestCase`)

- Engine attached (`FakeSearchEngine` with `scriptedHits` of an
  engine-only note A linked to note B), `include_linked: true` ->
  `retrieval == "search-engine"`, A has `provenance.sources` containing
  `"search-engine"`, B has `is_linked_neighbor == true` and
  `provenance.sources == ["graph-neighbor"]`, and `recordedSearches` is not
  empty.
- Engine attached, `include_linked: false` -> `retrieval ==
  "search-engine"`, every result has the 8 original keys plus
  `provenance`, and there are no other keys.
- No engine, `include_linked: true` -> the output equals the output of the
  FTS path for the same input (compare the parsed JSON objects), with no
  `provenance` key.
- Engine `failure = .unavailable("x")`, `include_linked: true` ->
  `retrieval == "full-text"`, no `provenance` key, and the results equal
  `service.searchNotes(... includeLinked: true ...)` ids.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P4
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P4/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "AgentSearchNotesFusionTests|AgentSearchNotesRoutingTests|KaibaAgentToolboxTests" 2>&1 | tee tmp/search-engine-fusion/P4/agent.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P4/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppCore/KaibaAgentToolbox.swift Tests/AppCoreTests/AgentSearchNotesFusionTests.swift Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift
git diff -- Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift
git diff --stat -- Sources/AppCore/KaibaAgentToolSchema.swift Tests/AppCoreTests/KaibaAgentToolboxTests.swift
wc -l Sources/AppCore/KaibaAgentToolbox.swift
```

Expected evidence:

- build `exit=0`.
- The agent run shows `exit=0` and `Executed N tests, 0 failures` with
  N >= 4 new + 5 kept routing + the existing toolbox tests.
- The routing-test diff removes exactly one function.
- The schema and toolbox-test diff stat is empty.
- The toolbox file is under 600 lines.

## Done criteria

- [ ] `search_notes` uses `retrieveNotes` for both `include_linked`
      values.
- [ ] Output with no engine is byte-identical. Engine-mode output adds only
      `provenance`.
- [ ] Tests pass with positive counts. Evidence is recorded.

## Progress Log

- 2026-10-05: Plan created.
