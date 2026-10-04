# P16 Agent search_notes routing through the engine (D4)

**Status**: Ready
**planId**: P16-agent-search-routing
**Wave**: 1
**dependsOn**: none among dispatched plans. Accepted dependency: P5-engine-query-service, which provides `engineSearchNotes(query:notebookId:tagFilter:limit:offset:)`.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D4 "Agent and agentic-search boundary"
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

When a search engine is attached, the agent `search_notes` tool retrieves candidates from the engine. It falls back to the existing FTS path in two cases:

- when no engine is attached, `include_linked` is true, or the engine throws;
- when the engine call fails, so the agent never loses search.

The tool output contract stays the same, plus one added key. `AIAgenticSearch` grounding is unchanged and stays on FTS.

Repository facts:

- `Sources/AppCore/KaibaAgentToolbox.swift` (480 lines):
  - `execute(_:) async` (around line 21) calls the synchronous `run(_:)`;
  - `run` dispatches `"search_notes"` to `searchNotes(_:)` (around lines 87-118).
- `searchNotes(_:)` parses `query`, `notebook_id`, `tags`, `include_linked` and `limit` (1...50, default 10). It calls `service.searchNotes(query:tagFilter:notebookId:includeLinked:depth: 1, limit:)` and returns:
  - `{query, results: [{note_id, notebook_id, title, snippet, updated_at, term_coverage, is_linked_neighbor, tags}]}`.
- Supporting pieces:
  - `NoteService.isSearchEngineEnabled` and `engineSearchNotes(...)` are in `NoteService+SearchEngine.swift`;
  - `indexableSearchTerms(from:)` is at `NoteSearchLexicalFusion.swift:38`; the FTS fusion computes `termCoverage = matched / terms.count` from it;
  - `noteRetrievalText(bodyMarkdown:searchText:)` and `noteSearchTexts(_:in:)` are the retrieval-text helpers used by the engine service;
  - the tool schema text is in `KaibaAgentToolSchema.swift` and must not change.

## Non-goals

- No change to `AIAgenticSearch.swift`, `AgentTools.swift` or `KaibaAgentToolSchema.swift`.
- No change to other tools, and no change to the FTS path's output.
- No graph-neighbor expansion on the engine path.

## writePaths

- `Sources/AppCore/KaibaAgentToolbox.swift`
- `Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift` (new)
- `impl-plans/active/search-engine-adapter-p16-agent-search-routing.md`

## sharedPaths (read-only)

- `Sources/AppCore/NoteService+SearchEngine.swift`: read-only. `engineSearchNotes` and `isSearchEngineEnabled`.
- `Sources/AppCore/NoteSearchLexicalFusion.swift`: read-only. `indexableSearchTerms(from:)`.
- `Sources/AppCore/KaibaAgentToolSchema.swift`: read-only. The tool contract; must stay unchanged.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only. The P1 fake, extended by P12 in the same wave. Use only the base knobs: `failure`, `scriptedHits` and `documents` via `apply`.

## File-level changes (`KaibaAgentToolbox.swift`)

1. In `execute(_:)`, before calling `run`, branch on `call.name == "search_notes"` to a new `private func searchNotesRouted(_ input: KaibaAgentToolInput) async throws -> JSONValue`. Keep the same success and error wrapping.
2. `searchNotesRouted` parses the inputs exactly as `searchNotes` does, reusing a small shared parse helper so validation errors stay identical. Then:
   - **Engine path.** When `service.isSearchEngineEnabled && !includeLinked`, call `try await service.engineSearchNotes(query:notebookId:tagFilter:limit:offset: 0)`.
     - On success, return the same JSON shape. For each hit:
       - `term_coverage` is the share of `indexableSearchTerms(from: query)` terms found case-insensitively in `(title ?? "") + " " + retrievalText`. The retrieval text comes from `noteRetrievalText` with `noteSearchTexts` in one `driver.withDatabase`. Use 0.0 when the term list is empty;
       - `is_linked_neighbor` is false;
       - `snippet` is the hit snippet;
       - `tags` is `Self.tagNames(note.tags)`.
     - Add the top-level key `"retrieval": "search-engine"`.
   - **Fallback.** Catch only `SearchEngineError` from the engine call, and fall through to the FTS path. Other errors propagate as they would from FTS, for example `invalidInput`.
   - **FTS path.** Run the existing `searchNotes(_:)` logic unchanged, adding `"retrieval": "full-text"` at the top level.
3. Keep `run`'s `"search_notes"` case working for any synchronous caller (it returns the FTS path), so `run` stays total.
4. Budget: the file stays under 560 lines.

## Pitfalls

- **Fallback scope.** Only `SearchEngineError` triggers the FTS fallback. Any other error from `engineSearchNotes`, for example `NoteServiceError.invalidInput` for a blank query, becomes the tool's error result, as on the FTS path.
- **Output keys.** Do not rename existing keys. The schema description stays word-for-word.
- **No engine in the toolbox's service.** `isSearchEngineEnabled` is false, so the FTS path runs and the output differs only by the `retrieval` key.
- **Do not edit `FakeSearchEngine.swift`.** It belongs to P12 in this wave.
- **The fake matches whole queries only.** Its non-scripted `search` returns a document only when the whole lowercased query is a substring of the document text. A multi-word query like "alpha gamma" therefore matches nothing. Engine-path tests must drive hits with the `scriptedHits` base knob, and the store re-check then hydrates the real note.

## Tests (`AgentSearchNotesRoutingTests`, XCTest)

- No engine -> `retrieval == "full-text"`, and the results equal the FTS results for the same query, compared by note ids.
- Note N is created in the store with body `alpha beta`. The engine is attached as a `FakeSearchEngine` with `scriptedHits = [SearchEngineHit(noteId: N, score: 1, highlight: nil)]`. Query `"alpha gamma"` -> `retrieval == "search-engine"`, the results contain N, `term_coverage == 0.5` (one of two terms present), and `is_linked_neighbor == false`. Keep the 0.5 assertion. Do not change the query to make the fake match.
- Engine attached and `include_linked: true` -> `retrieval == "full-text"`.
- Engine attached with `failure = .unavailable("x")` -> `retrieval == "full-text"` and results are returned, with no error result.
- Engine attached and the hits' notes are in an unreachable library -> the re-check drops them, so the engine path returns an empty result list with no error.
- `limit: 0` -> the same validation error text as before (`isError == true`).

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P16 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter AgentSearchNotesRouting 2>&1 | tee tmp/search-engine-adapter/P16/routing.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P16 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter KaibaAgentToolboxTests 2>&1 | tee tmp/search-engine-adapter/P16/toolbox-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P16 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P16/lint.log; echo exit=${PIPESTATUS[0]}'
git diff --stat -- Sources/AppCore/KaibaAgentToolSchema.swift Sources/AppCore/AIAgenticSearch.swift
wc -l Sources/AppCore/KaibaAgentToolbox.swift
```

Expected evidence:

- Both `swift test` runs show `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0. If no suite matches `KaibaAgentToolbox`, use the existing toolbox test class name (find it with `grep -rln KaibaAgentToolbox Tests/AppCoreTests`) and log it.
- `git diff --stat` prints nothing for the schema and AIAgenticSearch files.
- The file has fewer than 560 lines.

## Done criteria

- [ ] `search_notes` uses the engine when one is attached and `include_linked` is false, and falls back to FTS on `SearchEngineError`.
- [ ] Output keys are unchanged, plus `retrieval`.
- [ ] The schema and `AIAgenticSearch` are untouched.
- [ ] All verification shows `exit=0` with positive counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
