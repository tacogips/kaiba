# P15 Ontology query service: D2 filters, expansion and facets; D3 related signals and reasons

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P15-ontology-query-service
**Wave**: 2
**dependsOn**: P12-delta-contract. Accepted dependency: P5-engine-query-service.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` D2 "Service behavior" and "Facet access rule"; D3 "Signals" and "Reasons"; D4, first bullet (no LLM); SE4 (unchanged access control)
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

`engineSearchNotes` gains four things, all computed deterministically from store SQL and passed to the engine through the P12 types:

- hierarchical tag filters, resolved to tag ids with no SQL descendant expansion;
- tag-class filters;
- query-time ontology expansion;
- optional facets.

`relatedNotes` sends the D3 related signals and returns per-hit reasons, enriched from the store.

SE4 still applies unchanged: the engine filter plus the store re-check (`scopedNoteIds`). No LLM is involved anywhere.

Repository facts:

- `Sources/AppCore/NoteService+SearchEngine.swift` (126 lines) has `engineSearchNotes(query:notebookId:tagFilter:limit:offset:)` and `relatedNotes(noteId:limit:)`. Both follow three phases: store prepare, then the engine call, then store re-check and hydration.
- `Sources/AppCore/SearchEngineScope.swift` has `searchEngineFilter(for:tagIds:excludedNoteIds:)` and `scopedNoteIds`.
- `resolveTagIds(named:in:)` is at `NoteTagHierarchy.swift:42`.
- Tags: `tags(tag_id, name, class_id, parent_tag_id, is_system)`. Classes: `tag_classes(class_id)`.
- Existing GraphQL (P6) and P16 call `engineSearchNotes(query:notebookId:tagFilter:limit:offset:)`. That signature and its return type must stay.

## Non-goals

- No change to `searchNotes`, `NoteSearch*.swift`, or the SE4 predicates.
- No GraphQL change (P18) and no adapter change (P13).
- No configurable boosts.
- No reasons for search hits beyond what the engine returns.

## writePaths

- `Sources/AppCore/NoteService+SearchEngine.swift`
- `Sources/AppCore/NoteService+SearchEngineOntology.swift` (new)
- `Sources/AppCore/SearchEngineScope.swift`
- `Tests/AppCoreTests/SearchEngineOntologyQueryTests.swift` (new)
- `Tests/AppCoreTests/SearchEngineQueryTests.swift`. Only one change is allowed: the assertion at about line 96, which expects `filter.tagIds == [parent, child]` (SQL-expanded), becomes `filter.hierarchyTagIds == [parent]` and `filter.tagIds == []`. This is the intended D2 change. Everything else in the file stays unchanged.
- `impl-plans/completed/search-engine-adapter-p15-ontology-query-service.md`

## sharedPaths (read-only)

- `Sources/AppCore/SearchEngine.swift`: read-only. The P12 types.
- `Sources/AppCore/NoteTagHierarchy.swift`: read-only. `resolveTagIds(named:in:)`.
- `Sources/AppCore/NoteSearch.swift`: read-only. `snippet(from:query:)` and `NoteSearchScope`.
- `Tests/AppCoreTests/FakeSearchEngine.swift`: read-only. The P12 fake, with `scriptedHits`, `scriptedFacets`, `recordedSearchPages` and `recordedRelated`.
- `Tests/AppCoreTests/SearchEngineAccessTests.swift`: read-only. Access-test patterns. These must keep passing.

## File-level changes

### `NoteService+SearchEngine.swift`

**New pinned API (P18 depends on it):**

```swift
func engineSearchNotesPage(
  query: String, notebookId: NotebookID? = nil, tagFilter: [String] = [],
  tagClassFilter: [String] = [], expandOntology: Bool = true, includeFacets: Bool = false,
  limit: Int = 20, offset: Int = 0
) async throws -> NoteEngineSearchPage
```

**Old method.** `engineSearchNotes(query:notebookId:tagFilter:limit:offset:)` keeps its exact signature and returns `try await engineSearchNotesPage(..., expandOntology: true, includeFacets: false).hits`.

**Prepare phase** (one `driver.withDatabase`):

1. Build the scope as today. When the scope is `[]`, the page is empty.
2. `tagFilter` -> `resolveTagIds(named:)`, with no descendant expansion. If the filter is non-empty and resolves to nothing, the page is empty.
3. `tagClassFilter`, through `resolveTagClassFilters`. More than 10 entries throws `NoteServiceError.invalidInput("tagClassFilter allows at most 10 entries")`. An unresolvable entry makes the page empty.
4. When `expandOntology` is true, `ontologyExpansionTagIds(query:in:)`.

**Engine filter.** Set `hierarchyTagIds` to the resolved ids and `tagIds: []`. Set `tagClassFilters`. Then call `engine.searchPage(SearchEngineQuery(..., expansionTagIds:, facets: includeFacets ? SearchEngineFacetRequest() : nil))`.

**Re-check and hydration.** These run as today. Each hit carries `reasons: hit.reasons`.

**Facets.** When present, hydrate them through `hydrateEngineFacets(_:in:)` and return them as `NoteEngineSearchFacets`. Without the request, facets are nil.

**`relatedNotes(noteId:limit:)`.**

- In the prepare phase, also compute `relatedSignals(forSourceNoteId:in:)` and pass `signals` in `SearchEngineRelatedQuery`.
- After the re-check and page slicing, call `enrichRelatedReasons(_:sourceSharedTagIds:in:)`, inside the same `withDatabase` that hydrates the notes.

### `NoteService+SearchEngineOntology.swift` (new; internal helpers taking `in database: SQLiteDatabase`)

**`ontologyExpansionTagIds(query: String, in:) -> [TagID]`.** This is the exact D2 rule:

- Normalize with Unicode lowercase, trim, and collapse whitespace runs into one space.
- Candidates are non-system tags (`is_system = 0`) whose normalized name has at least 2 characters and occurs in the normalized query.
- For an ASCII alphanumeric first character, the preceding query character must not be ASCII alphanumeric. The same holds for the last character and the following character.
- Rank longer names first, then by `tagId`, and cap at 10.

Candidate selection may use SQL `instr(?, lower(name)) > 0` as a prefilter. The final checks must run in Swift, because SQLite `lower()` is ASCII-only. Normalize again in Swift, and treat the SQL prefilter only as an optimization. If in doubt, load the non-system tag names and filter in Swift.

**`resolveTagClassFilters(_ entries: [String], in:) -> [SearchEngineTagClassFilter]?`.** It returns nil when the page must be empty.

- Split each entry at the first `:`.
- The class must exist in `tag_classes`.
- The tag name must resolve through `resolveTagIds(named:)`, and the tag's `class_id` must equal the class.

**`relatedSignals(forSourceNoteId:in:) -> SearchEngineRelatedSignals`.**

- `S`: the source's direct non-system tags.
- `P`: the non-null, non-system parents of `S`.
- `A`: all ancestors of `S`, excluding `S` and system tags. Use a recursive CTE, depth at most 64.
- `nearTagIds`: `S` union `P`, deduplicated and sorted.
- `E`: `SearchEngineClassTag` pairs for tags in `S` whose class is `person` or `event`.
- Cap each list at 50, after sorting by `tagId`.

**`hydrateEngineFacets(_:in:) -> NoteEngineSearchFacets`.**

- Class buckets pass through.
- Tag buckets map their value to `TagID`, load `name`, `class_id` and `is_system`, and drop unknown or system tags. Keep the engine order.

**`enrichRelatedReasons(_ hits: [NoteEngineSearchHit], sourceSharedTagIds: [TagID], in:) -> [NoteEngineSearchHit]`.** For `sharedTag` and `sharedEntity` reasons:

- `tagNames` are the names of the hit note's direct non-system tags that are in `S`, sorted, at most 5.
- If that set is empty because the index is stale, drop the reason.

Other reasons pass through unchanged. The hit itself is never dropped here.

### `SearchEngineScope.swift`

Extend `searchEngineFilter(for:tagIds:excludedNoteIds:)` with defaulted parameters `hierarchyTagIds: [TagID] = []` and `tagClassFilters: [SearchEngineTagClassFilter] = []`, which fill the new filter fields. Do not change `scopedNoteIds`.

## Pitfalls

- **Access.** Facets and expansion never bypass the re-check. Reasons are computed only for hits that survived it.
- **Old method compatibility.** `engineSearchNotes` callers (GraphQL P6 and P16) keep compiling, and expansion is now on by default for them, as intended.
- **Unicode.** Do the normalization and boundary checks in Swift on `Character`/`Unicode.Scalar`. "ASCII alphanumeric" means `[A-Za-z0-9]` only.
- **Fake recording.** After this plan, `engineSearchNotes` calls `engine.searchPage`. The accepted P5 tests still pass only because P12's `FakeSearchEngine.searchPage` delegates to `search`, so each call also appends to `recordedSearches`, including with `scriptedHits`. Do not edit the fake. Do not edit any P5 test assertion other than the `SearchEngineQueryTests.swift` line-96 change. If those tests fail on recording counts, record `blocked by peer P12-delta-contract` instead of weakening them.
- **No LLM.** Do not import or reference any AI, agent, provider or `AIAgenticSearch` type in these files. P21 greps for it.
- **Determinism.** Every list is sorted before capping.

## Tests (`SearchEngineOntologyQueryTests`, XCTest, with `FakeSearchEngine`)

**Filters:**

- `tagFilter ["parent"]`, where `child` is under `parent` -> the recorded query has `hierarchyTagIds == [parent]` and `tagIds == []`.
- `tagFilter ["nope"]` -> empty page, and no engine call recorded.
- `tagClassFilter ["person"]` -> one filter `(person, nil)`.
- `["person:Alice"]`, where Alice has class `person` -> `(person, Alice)`.
- `["event:Alice"]` -> empty page with no engine call.
- `["bogus"]` (unknown class) -> empty page.
- 11 entries -> `NoteServiceError.invalidInput`.

**Expansion:**

- Query `"東京旅行"` with tag `東京` -> expansion contains it.
- Query `"party"` with tag `art` -> no expansion. Query `"art history"` with tag `art` -> expansion contains it.
- A system tag with a matching name -> excluded.
- 12 matching tags -> 10, longest first.
- `expandOntology: false` -> `expansionTagIds == []`.

**Facets:**

- `includeFacets: true`, with scripted facets including an unknown tag id and a system tag -> both dropped, the names and classes hydrated, and the class buckets passed through.
- `includeFacets: false` -> the query's facets are nil and the page's facets are nil.

**Related:**

- Source with tags `{Alice (person), Topic}` under parent `P`, where `Topic` has ancestors -> the recorded signals have S, near equal to S union P, A, `E == [(person, Alice)]`, and `sourceNoteId`.
- Scripted hits with reason `sharedTag`, where the hit shares `Topic` -> `tagNames == ["Topic"]`.
- A hit whose `sharedTag` reason is unsupported by the store -> that reason is dropped and the hit is kept.
- A source hit scripted into the results -> never returned.
- A filter-ignoring fake returning a note from an unreachable library -> dropped by the re-check.

**No LLM:** a store with no AI configuration -> `engineSearchNotesPage` and `relatedNotes` complete successfully.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P15 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineOntologyQuery 2>&1 | tee tmp/search-engine-adapter/P15/ontology-query.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P15 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineQuery 2>&1 | tee tmp/search-engine-adapter/P15/query-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P15 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter SearchEngineAccess 2>&1 | tee tmp/search-engine-adapter/P15/access-regression.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P15 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P15/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c '! grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+SearchEngine.swift Sources/AppCore/NoteService+SearchEngineOntology.swift Sources/AppCore/SearchEngineScope.swift'
wc -l Sources/AppCore/NoteService+SearchEngine.swift Sources/AppCore/NoteService+SearchEngineOntology.swift Sources/AppCore/SearchEngineScope.swift
```

Expected evidence:

- Every `swift test` run shows `exit=0` with an XCTest `Executed N tests, 0 failures`, N > 0.
- The boundary grep exits 0.
- All files are under 1000 lines.

## Done criteria

- [x] `engineSearchNotesPage` exists with the pinned signature. The old `engineSearchNotes` is unchanged in signature.
- [x] Filters, expansion and facets follow the D2 rules exactly, and related signals and reasons follow D3.
- [x] The SE4 access tests still pass.
- [x] All behavioral verification shows `exit=0` with positive XCTest counts.

## Progress Log

- 2026-10-04: Plan created (session-264).
- 2026-10-04: Implemented P15 on the shared branch. Added `engineSearchNotesPage` while retaining the old wrapper, and added deterministic hierarchy/class filters, Unicode ontology expansion, optional facet hydration, bounded related signals, and store-confirmed related reasons. Added `SearchEngineOntologyQueryTests`; changed only the planned hierarchy filter assertion in `SearchEngineQueryTests`. SE4 re-checks remain in place.
- Current-source verification: `mise run build` exit 0 (`tmp/search-engine-adapter/P15/build-final2.log`); `swift test --filter SearchEngineOntologyQuery` 4 XCTest, 0 failures, exit 0 (`ontology-query-final-source.log`); `--filter SearchEngineQuery` 5 XCTest, 0 failures, exit 0 (`query-regression-final-source.log`); `--filter SearchEngineAccess` 6 XCTest, 0 failures, exit 0 (`access-regression-final-source.log`). Strict changed-file SwiftLint exit 0 (`swiftlint-changed-final.log`). `mise run lint` exit 0 with 3 unrelated existing findings in `NoteService.swift:729`, `ResendGatewayCLIMailSender.swift:75`, and `AITranslationTests.swift:71` (`lint-final.log`). The no-AI boundary grep and `git diff --check` exit 0 (`no-ai-boundary.log`, `diff-check.log`); source line counts are 193, 206, and 65 (`wc-lines.log`).
- Superseded attempts retained: initial `build.log` exposed the invalid optional binding for `TagID`; fixed and rebuilt. Initial `ontology-query.log` failed two assertions because the fixture query did not contain its candidate names; corrected the fixture and the final-source rerun passed 4/4.
- Formal adversarial/test-integrity review and downstream P18 integration remain workflow-owned follow-up steps.
