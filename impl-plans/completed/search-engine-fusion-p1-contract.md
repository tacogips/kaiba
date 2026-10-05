# P1 Fusion contract: reranker, provenance field, transport move

**Status**: Completed. Accepted in session-268 (test-integrity, adversarial and combined-tree integration review, comm-004081). The P10 combined-tree gates passed (`impl-plans/completed/search-engine-fusion.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P1-fusion-contract
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F2 (Types, Rules, Weights), F3 "Files and transport", F1 step 6 (visibility of `appendLinkedNeighborResults`)
**Index**: `impl-plans/completed/search-engine-fusion.md`

## Intent and context

This plan pins the shared AppCore contract that the wave-2 and wave-3
plans build on:

1. A pure, engine-neutral reranker, `NoteRetrievalReranker.fuse`, with its
   value types and policy constants.
2. An optional `provenance` field on `NoteSearchResult`, defaulting to nil
   so existing results and equality checks do not change.
3. The `NoteRetrievalOutcome` value type, returned by P2's
   `retrieveNotes`.
4. `appendLinkedNeighborResults` made `internal` so P2 can seed PPR from
   fused hits.
5. The HTTP transport moved to an adapter-neutral file, with type aliases
   that keep Elasticsearch code and tests compiling unchanged, so the P3
   Meilisearch adapter does not depend on Elasticsearch-named types.

Repository facts:

- `Sources/AppCore/NoteSearchLexicalFusion.swift:reciprocalRankFusion(lists:k:)`
  computes `weight / (k + position)` with 1-based positions.
  `NoteSearchFusionPolicy.reciprocalRankK = 60`.
- `Sources/AppCore/NoteModels.swift:NoteSearchResult` (line ~532) has a
  memberwise `public init(note:snippet:rank:matchedTags:isLinkedNeighbor:termCoverage:)`.
- `Sources/AppCore/SearchEngine.swift:SearchEngineHitReasonKind` declares,
  in this order: textMatch, tagMatch, tagHierarchyMatch, textSimilarity,
  sharedTag, relatedTag, sharedEntity, linked. It is not `CaseIterable`.
  Do not edit `SearchEngine.swift`.
- `Sources/AppCore/NoteSearch.swift:597` has
  `private func appendLinkedNeighborResults(to:query:tagFilterIds:classFilter:scope:sort:depth:limit:in:)`.
- `Sources/AppCore/ElasticsearchHTTPTransport.swift` contains
  `protocol ElasticsearchHTTPTransport`,
  `struct URLSessionElasticsearchTransport` (with `supportsInsecureTLS` and
  `init(insecureTrustHost:)`) and the private `ElasticsearchTrustDelegate`.
- `Sources/AppCore/SearchEngineFactory.swift` refers to
  `ElasticsearchHTTPTransport` and
  `URLSessionElasticsearchTransport.supportsInsecureTLS`. Those names must
  keep compiling through the aliases.

## Non-goals

- No service logic. `retrieveNotes` belongs to P2.
- No change to `SearchEngine.swift`, `SearchEngineFactory.swift`,
  `ElasticsearchSearchEngine.swift`, `ElasticsearchRequestBodies.swift`,
  `AIAgenticSearch.swift` or `KaibaAgentToolbox.swift`.
- No change to any search behavior. The FTS path, PPR and grounding produce
  identical results.

## writePaths

- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/NoteModels.swift`
- `Sources/AppCore/NoteSearch.swift`
- `Sources/AppCore/SearchEngineHTTPTransport.swift`
- `Sources/AppCore/ElasticsearchHTTPTransport.swift`
- `Tests/AppCoreTests/NoteRetrievalRerankerTests.swift`
- `impl-plans/completed/search-engine-fusion-p1-contract.md`
- `tmp/search-engine-fusion/P1`

## sharedPaths (read-only)

- `Sources/AppCore/NoteSearchLexicalFusion.swift`
- `Sources/AppCore/SearchEngine.swift`
- `Sources/AppCore/SearchEngineFactory.swift`

## sharedPathNotes

- `Sources/AppCore/NoteRetrievalReranker.swift`: intendedEdit: new file holding the reranker types, policy and `fuse`.
- `Sources/AppCore/SearchEngineHTTPTransport.swift`: intendedEdit: new file holding the moved transport.
- `Tests/AppCoreTests/NoteRetrievalRerankerTests.swift`: intendedEdit: new test file.
- `Sources/AppCore/NoteSearchLexicalFusion.swift`: intendedEdit: read-only; reuse `reciprocalRankFusion` and `NoteSearchFusionPolicy`.
- `Sources/AppCore/SearchEngine.swift`: intendedEdit: read-only; use `SearchEngineHitReasonKind`.
- `Sources/AppCore/SearchEngineFactory.swift`: intendedEdit: read-only; it must keep compiling through the transport aliases.
- `tmp/search-engine-fusion/P1`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P1`

## File-level changes

### `NoteRetrievalReranker.swift` (new, target under 250 lines)

Pin these public or internal shapes exactly. P2, P3, P4, P5 and P6 rely
on them.

```swift
public enum NoteRetrievalSource: String, CaseIterable, Equatable, Sendable {
  case searchEngine = "search-engine", fullText = "full-text", agentQuery = "agent-query", graphNeighbor = "graph-neighbor"
}
public struct NoteRetrievalProvenance: Equatable, Sendable {
  public var sources: [NoteRetrievalSource]
  public var reasons: [SearchEngineHitReasonKind]
  public init(sources: [NoteRetrievalSource] = [], reasons: [SearchEngineHitReasonKind] = [])
}
public struct NoteRetrievalOutcome: Equatable, Sendable {
  public var results: [NoteSearchResult]
  public var usedSearchEngine: Bool
  public init(results: [NoteSearchResult], usedSearchEngine: Bool)
}
enum NoteRetrievalTier: Equatable, Sendable { case direct, neighbor }
struct NoteRetrievalCandidateEntry: Equatable { var noteId: NoteID; var provenance: NoteRetrievalProvenance }
struct NoteRetrievalCandidateList { var label: NoteRetrievalSource?; var weight: Double; var tier: NoteRetrievalTier; var entries: [NoteRetrievalCandidateEntry] }
struct NoteRetrievalFusedCandidate: Equatable { var noteId: NoteID; var score: Double; var tier: NoteRetrievalTier; var provenance: NoteRetrievalProvenance }
enum NoteRetrievalFusionPolicy {
  static let k = NoteSearchFusionPolicy.reciprocalRankK  // 60
  static let maximumLists = 16
  static let maximumCandidatesPerList = 1000
  static let maximumEngineCandidates = 200
  static let maximumFusedWindow = 1000
}
enum NoteRetrievalReranker {
  static func fuse(_ lists: [NoteRetrievalCandidateList], limit: Int) -> [NoteRetrievalFusedCandidate]
}
```

Add `NoteRetrievalProvenance.normalized()` (or an equivalent internal
helper), which deduplicates and orders sources by `NoteRetrievalSource.allCases`
order and reasons by a fixed array listing the eight
`SearchEngineHitReasonKind` cases in their declaration order. Define that
array in this file; do not edit `SearchEngine.swift`.

Rules for `fuse`, from design F2:

1. Use at most the first `maximumLists` lists. Truncate each list to
   `maximumCandidatesPerList` entries, then keep only the first occurrence
   of each note id within the list.
2. Score each note as the sum over containing lists of
   `weight / (k + position)`, with 1-based positions. Compute it with
   `reciprocalRankFusion`, or with the identical arithmetic in the same
   list order, so that floating-point sums match the existing grounding
   code exactly.
3. A note is `direct` if it occurs in any direct list. A neighbor-list
   entry whose note is direct contributes neither score nor provenance.
4. Order: the direct tier first; within a tier, score descending, then
   `noteId` ascending (`NoteID <`). Truncate the output to `max(0, limit)`.
5. Provenance is the union of each contributing entry's provenance plus
   the contributing list's `label` (when non-nil), normalized.
6. The function is pure. It never iterates a dictionary to decide order.
   Collect first-seen order in arrays and sort with the explicit
   comparator.

### `NoteModels.swift`

- Add `public var provenance: NoteRetrievalProvenance?` to
  `NoteSearchResult`.
- Add the init parameter `provenance: NoteRetrievalProvenance? = nil` as
  the last parameter.
- Extend the `rank` doc comment with: "the fused reciprocal-rank score
  (higher is better) for a direct hit of engine-seeded retrieval".
- The file grows by less than 10 lines.

### `NoteSearch.swift`

- Change only `private func appendLinkedNeighborResults` to `func`
  (internal). Make no other change. The file stays at 876 lines.

### Transport move

- New `SearchEngineHTTPTransport.swift`: move the protocol, the URLSession
  transport and the trust delegate verbatim from
  `ElasticsearchHTTPTransport.swift`, renamed:
  - `protocol SearchEngineHTTPTransport`;
  - `struct URLSessionSearchEngineTransport`, keeping `supportsInsecureTLS`
    and `init(insecureTrustHost:)`;
  - `private final class SearchEngineTrustDelegate`.

  Keep the `#if canImport(FoundationNetworking)` and
  `#if canImport(Security)` guards exactly.
- `ElasticsearchHTTPTransport.swift` becomes the imports plus
  `typealias ElasticsearchHTTPTransport = SearchEngineHTTPTransport` and
  `typealias URLSessionElasticsearchTransport = URLSessionSearchEngineTransport`.

## Invariants

- No existing test file changes. Every existing AppCore test compiles and
  passes, in particular `NoteRetrievalFusionTests`,
  `ElasticsearchSearchEngineTests` and `SearchEngineFactoryTests`.
- Elasticsearch requests are byte-identical. The transport behavior is
  moved, not modified.
- `NoteSearchResult` values built by existing code have `provenance == nil`.

## Pitfalls

- Do not make `NoteRetrievalProvenance` `Codable` in AppCore. GraphQL
  builds its own DTO in P6.
- Do not add a tie-break other than `noteId` ascending. Grounding
  equivalence (P5) depends on it.
- A list with `weight <= 0`: skip it, so it contributes nothing.
- `limit == 0` returns `[]`. Empty input returns `[]`.
- Do not change the `ElasticsearchSearchEngine` initializer signature. It
  takes `(any ElasticsearchHTTPTransport)?`, which now resolves through the
  alias.
- The moved trust delegate must stay `@unchecked Sendable` and keep
  matching hosts case-insensitively.

## Tests (`NoteRetrievalRerankerTests`, XCTest, pure, no store)

- One direct list `[a, b, c]`, weight 1 -> the output order is `[a, b, c]`
  and the scores strictly decrease.
- Lists `full-text [a, b]` and `search-engine [b, c]`, weight 1 each -> `b`
  is first. `a` and `c` tie on score and are ordered by note id.
  Provenance of `b` is `[search-engine, full-text]`.
- Grounding equivalence: lists of note ids with weights `2, 1, 1` -> the
  order equals sorting `reciprocalRankFusion` scores descending, then by
  note id ascending.
- Dedupe: list `[a, a, b]` -> `a` scores at position 1 only.
- Tiers: direct `[a]` and neighbor `[a, n]` -> output `[a(direct), n(neighbor)]`.
  `a` gets no `graph-neighbor` source.
- Entry reasons `[tagMatch, textMatch]` and `[linked]` across lists -> the
  reasons are normalized to declaration order: `[textMatch, tagMatch, linked]`.
- Caps: 17 lists -> the 17th is ignored. 1001 entries -> entry 1001 is
  absent. `limit: 2` -> 2 results.
- `limit: 0` and empty input -> `[]`.
- A `NoteSearchResult` built with the old init has `provenance == nil`.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P1
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P1/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteRetrievalRerankerTests 2>&1 | tee tmp/search-engine-fusion/P1/reranker.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "NoteRetrievalFusionTests|ElasticsearchSearchEngineTests|SearchEngineFactoryTests|NoteServiceTests" 2>&1 | tee tmp/search-engine-fusion/P1/regression.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P1/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Sources/AppCore/NoteRetrievalReranker.swift Sources/AppCore/SearchEngineHTTPTransport.swift Sources/AppCore/ElasticsearchHTTPTransport.swift Sources/AppCore/NoteModels.swift Sources/AppCore/NoteSearch.swift Tests/AppCoreTests/NoteRetrievalRerankerTests.swift
git diff --stat -- Tests/AppCoreTests Sources/AppCore/SearchEngine.swift Sources/AppCore/SearchEngineFactory.swift Sources/AppCore/ElasticsearchSearchEngine.swift Sources/AppCore/ElasticsearchRequestBodies.swift
git diff -- Sources/AppCore/NoteSearch.swift
wc -l Sources/AppCore/NoteRetrievalReranker.swift Sources/AppCore/NoteModels.swift Sources/AppCore/NoteSearch.swift
```

Expected evidence:

- build `exit=0`.
- The reranker run shows `exit=0` and `Executed N tests, 0 failures` with
  N >= 9.
- The regression run shows `exit=0` and N > 0.
- Strict swiftlint on the touched files prints no violations.
- The `git diff --stat` shows only the new reranker test file under
  `Tests/AppCoreTests`, and nothing for the listed Elasticsearch, factory
  and protocol sources.
- The `NoteSearch.swift` diff is the single `private` removal.
- Every touched file is under 1000 lines.

## Done criteria

- [x] The types and `fuse` exist with the pinned signatures.
- [x] `NoteSearchResult.provenance` exists with a nil default.
- [x] `appendLinkedNeighborResults` is internal.
- [x] The transport is moved behind aliases. The Elasticsearch tests pass
      unchanged.
- [x] Reranker tests and regression suites pass with positive XCTest
      counts. Lint is clean on the touched files.
- [x] The progress log records the commands, log paths and exit codes.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Implemented the shared reranker/provenance contract, the
  default-nil `NoteSearchResult.provenance`, internal PPR helper visibility,
  transport move and Elasticsearch compatibility aliases. Added nine pure
  reranker tests. The first focused run failed one mathematically incorrect
  tie fixture (`reranker.log`, exit 1; 9 tests, 1 failure); corrected its ranks
  and reran on current source (`reranker-rerun.log`, exit 0; 9 tests, 0
  failures). Build passed (`build.log`, exit 0). The regression filter passed
  (`regression.log`, exit 0; 67 tests, 0 failures). Strict SwiftLint on the
  exact changed-file set passed (`swiftlint-strict-rerun.log`, exit 0).
  Repository-wide `mise run lint` exited 0 (`lint.log`) and reported three
  warnings in untouched `NoteService.swift`, `ResendGatewayCLIMailSender.swift`
  and `AITranslationTests.swift`. `git diff --check` passed and a normalized
  rename comparison confirmed `SearchEngineHTTPTransport.swift` matches the
  original transport (`transport_rename_cmp_exit=0`). All touched Swift files
  are under 1000 lines. Independent review remains downstream.
