# Search Engine Fusion and Lightweight Engine Adapter

## Status

Accepted (2026-10-05, comm-003999) and implemented in session-268
(2026-10-05). The combined-tree integration review accepted plans P1-P10
(comm-004081). This design extends
`design-docs/specs/search-engine-adapter.md` (SE1-SE9, D0-D5) and
`design-docs/specs/note-retrieval-fusion.md` (RF1-RF5). It does not
redesign them. Where a section below changes an earlier rule, it names the
rule, and the earlier text stays as the base record.

## Traceability

- Request: workflow issue "Search engine: engine-seeded graph search and
  search_notes, unified reranking across agent/engine/FTS/graph results,
  and a lightweight non-JVM engine adapter (Meilisearch first)". Goals G1,
  G2 and G3 map to F1, F2 and F3-F5 below.
- Base designs: `search-engine-adapter.md` (protocol SE1, access SE4,
  GraphQL SE5, adapter SE8, tooling SE9, ontology D1-D3, agent boundary D4,
  settings D5) and `note-retrieval-fusion.md` (RRF convention RF2, PPR
  RF3, agentic grounding RF5).
- Decisions and open questions:
  `design-docs/user-qa/search-engine-adapter.md`, section
  "Fusion and lightweight engine (2026-10-05)".
- Implementation plan: `impl-plans/completed/search-engine-fusion.md` with
  plans P1-P10 and the dispatch manifest
  `impl-plans/active/search-engine-fusion-dispatch.json`. All plans are
  completed and archived under `impl-plans/completed/` with their original
  file names. The dispatch manifest is a workflow runtime artifact and
  stays in `impl-plans/active/`.
- Code read for this design (current `main`):
  - `Sources/AppCore/NoteSearch.swift`: `searchNotesInDatabase`,
    `appendLinkedNeighborResults` (the only query-seeded graph expansion).
  - `Sources/AppCore/NoteGraphPersonalizedPageRank.swift`:
    `rankNeighborsByPersonalizedPageRank`.
  - `Sources/AppCore/NoteSearchLexicalFusion.swift`:
    `reciprocalRankFusion`, `NoteSearchFusionPolicy.reciprocalRankK = 60`,
    `indexableSearchTerms`.
  - `Sources/AppCore/AIAgenticSearch.swift`: `groundingResults` (full query
    weight 2 with `includeLinked`, per-term weight 1, ties by note id).
  - `Sources/AppCore/KaibaAgentToolbox.swift`: `searchNotesRouted` (D4).
  - `Sources/AppCore/NoteService+SearchEngine.swift`,
    `NoteService+SearchEngineOntology.swift`, `SearchEngineScope.swift`
    (`scopedNoteIds`, `searchEngineFilter`).
  - `Sources/AppCore/SearchEngineFactory.swift`,
    `NoteService+SearchEngineSettings.swift`,
    `Sources/AppServer/SearchEngineRuntimeController.swift`.
  - `Sources/AppGraphQL/NoteGraphQLDocumentExecutor.swift` and
    `NoteGraphQLService.swift` (`searchNotes`, `agenticSearch`).

## Problem

The optional engine is reachable only through `engineSearchNotes`,
`relatedNotes` and the agent `search_notes` tool with
`include_linked=false`. Graph search, the agent's graph search and the
agentic grounding pass rank only FTS hits, so an engine's ranking,
ontology expansion and CJK analysis never seed the graph and never reach
the agentic grounding document. Each path also fuses in its own way. The
only adapter needs a JVM, which is heavy for a single-user desktop setup.

## Scope

In scope:

- F1: engine-seeded retrieval for user-facing graph search
  (`searchNotes` with `includeLinked: true`), the agent `search_notes`
  tool (both `include_linked` values) and `AIAgenticSearch` grounding,
  with an exact FTS fallback.
- F2: one deterministic, engine-neutral reranker in AppCore with
  provenance, plus additive GraphQL and agent-output provenance.
- F3: a Meilisearch adapter behind the existing `SearchEngine` protocol.
- F4: Meilisearch in configuration and settings (descriptor, auth modes,
  validation). Hot-swap, test connection, config lock, outbox and
  backfill are reused unchanged.
- F5: local compose service, mise tasks and an env-gated live suite.
- F6: README, design and command documentation.

Out of scope:

- An LLM rerank, embeddings or vector search.
- Fusion for `searchNotes` with `includeLinked: false`, the
  `NoteSearchPopup` link picker, `kaiba search`, memo search and
  long-term-memory recall. They keep today's FTS path.
- Changes to `engineSearchNotes` or `relatedNotes` service behavior. They
  stay engine-only operations (SE5, D2, D3).
- Typesense and Manticore adapters (compared in F3, not built).
- Web display of provenance. The web client keeps its current rendering.
- Engine capability flags on the protocol (see F3 "Capability gaps").

## Invariants

1. **No engine means unchanged.** When no adapter is attached to the
   service slot, every F1 path runs today's code unchanged, with the same
   results, order, `rank` values, snippets and agent tool JSON. The
   reranker is not invoked on a path that has only one source list, so
   graph search and the agent tool run exactly today's functions.
   Agentic grounding already fuses several FTS lists today; it moves to
   the F2 reranker, whose output for FTS-only lists equals today's
   ordering (F2 rule 5).
2. **Engine failure means unchanged.** Any error thrown by an engine call
   (transport, timeout, rejection, invalid response, or
   `notConfigured` after a concurrent detach) discards all engine output
   of that retrieval call, and the call runs today's code. There is no
   partial engine contribution within one call.
3. **The store is the authority on access.** Every candidate that enters
   the reranker comes from a store query that applied today's predicates,
   or from an engine hit that passed the F1 store re-check. The reranker
   never adds ids that were not in its input lists.
4. **Callers see only the protocol.** F1 and F2 use `any SearchEngine`
   and adapter-neutral value types. Meilisearch JSON, filter syntax, task
   polling and URLs stay in `Sources/AppCore/Meilisearch*.swift`.
5. **No LLM in retrieval.** F1, F2 and F3 run only store SQL and engine
   requests. The D4 boundary grep is extended to the new files.
6. **Elasticsearch is unchanged.** The Elasticsearch adapter's requests,
   responses, index name and `indexIdentity` do not change. Its
   mock-transport tests pass unchanged.

## F1. Engine-seeded retrieval

### Entry point

New file `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`:

```swift
public struct NoteRetrievalOutcome: Equatable, Sendable {
  public var results: [NoteSearchResult]
  /// True only when an engine list was obtained and fused.
  public var usedSearchEngine: Bool
}

extension NoteService {
  public func retrieveNotes(
    query: String, tagFilter: [String] = [], classFilter: [String] = [],
    notebookId: NotebookID? = nil, sort: NoteListSort = .createdAtDesc,
    createdAfter: String? = nil, createdBefore: String? = nil,
    includeLinked: Bool = false, depth: Int = 1,
    limit: Int = 20, offset: Int = 0
  ) async throws -> NoteRetrievalOutcome
}
```

The parameters and their meaning are those of `searchNotes`.

### Algorithm

Let `window = offset + limit`, computed with the existing overflow guard.

1. **Engine-free short cut.** Run today's
   `searchNotes(...)` with the same arguments and return it with
   `usedSearchEngine: false` when any of these holds:
   - no adapter is attached (`searchEngine == nil`);
   - the trimmed query is empty (filter-only search; the engine rejects
     empty text);
   - `limit == 0`;
   - `window > NoteRetrievalFusionPolicy.maximumFusedWindow` (1000). Deep
     pages stay on FTS, which keeps the fused candidate count bounded.
2. **Prepare (one store read).** Build the scope with
   `makeNoteSearchScope(notebookId:createdAfter:createdBefore:in:)`.
   - `reachableLibraryIds == []`: return today's `searchNotes` result
     (it is empty) without calling the engine.
   - `tagFilter` names resolve through `resolveTagIds(named:)` and become
     `hierarchyTagIds`, as in D2. When `tagFilter` is non-empty and
     nothing resolves, return today's `searchNotes` result (empty).
   - Ontology expansion ids come from `ontologyExpansionTagIds(query:)`
     (D2, expansion on).
   - `classFilter` is not sent to the engine. Its D2 semantics differ
     from `searchNotes` (any-of direct class), so it is enforced only by
     the re-check in step 4.
3. **Engine call (no database handle held).** One
   `engine.search(SearchEngineQuery(text:filter:from: 0, size:expansionTagIds:))`
   with `size = min(window + 20, NoteRetrievalFusionPolicy.maximumEngineCandidates)`
   (`maximumEngineCandidates` = 200), no facets, and the SE4 filter built
   by `searchEngineFilter(for:tagIds: [], excludedNoteIds: [],
   hierarchyTagIds:)`. Any thrown error: go to step 1's FTS call and
   return `usedSearchEngine: false` (invariant 2).
4. **Store re-check and FTS (one `withDatabase`).**
   - Engine hits are deduplicated by note id, keeping the first, and
     re-checked by one SQL query that applies `scopedNoteIds`' predicates
     (notebook, library, owner, long-term memory, pending ingest,
     created-at) plus `appendTagPredicates` with the same
     `expandedTagFilterIds(names: tagFilter)` and `classFilter` that
     `searchNotesInDatabase` uses. Only surviving ids form the engine
     list, in engine order. The helper is
     `eligibleSearchCandidateIds(_:scope:tagFilterIds:classFilter:in:)`
     in the new file.
   - The FTS list is `searchNotesInDatabase(...)` with
     `includeLinked: false`, `limit: window`, `offset: 0`: today's strict,
     relaxed and substring stages, unchanged.
5. **Fuse direct hits.** `NoteRetrievalReranker.fuse` (F2) with two
   direct lists: `full-text` (the FTS list, weight 1.0) and
   `search-engine` (the engine list, weight 1.0, entries carrying the
   hit's reasons), `limit: window`.
6. **Graph expansion (only when `includeLinked`).** The fused direct
   results become the seeds of the existing
   `appendLinkedNeighborResults` (made `internal`, otherwise unchanged):
   at most `NoteGraphPolicy.maximumSeedCount` (20) seeds in fused order,
   the same traversal, eligibility predicates and PPR ranking (RF3). The
   resulting neighbor list (PPR order) is passed to a second
   `NoteRetrievalReranker.fuse` call as a neighbor-tier list labelled
   `graph-neighbor`. Its direct tier is identical to step 5 by
   construction, and neighbors fill only the `window - direct.count`
   remaining slots, as today.
7. **Hydrate and page.** Results are built for the window, then sliced to
   `[offset, offset + limit)`:
   - A note in the FTS list keeps its FTS `NoteSearchResult` (snippet,
     `termCoverage`, `matchedTags`). If the engine supplied a non-empty
     highlight, that highlight replaces the snippet.
   - An engine-only note is hydrated with `requireNotes` from an id that
     already passed the step 4 re-check, in the same database read. Its
     snippet is the engine highlight, or
     `snippet(from: retrievalText, query:)` when there is none. Its
     `termCoverage` uses the D4 rule: the share of
     `indexableSearchTerms(query)` found case-insensitively in the title
     plus retrieval text (0 when there are no indexable terms).
   - A graph neighbor keeps the result built by
     `appendLinkedNeighborResults` (`isLinkedNeighbor: true`, `rank` =
     PPR mass).
   - Direct results carry `rank` = the fused score (higher is better).
     The `NoteSearchResult.rank` doc comment gains this case.
   - Every result carries `provenance` (F2).
   - `usedSearchEngine: true`.

`sort` keeps its meaning inside the FTS list (tie order of the SQL
stages). The fused order breaks ties by note id (F2).

### Callers

| caller | today | with this design |
| --- | --- | --- |
| GraphQL `searchNotes`, `includeLinked: true` (document executor and `NoteGraphQLService.searchNotes`) | `searchNotes` | `retrieveNotes(...).results` |
| GraphQL `searchNotes`, `includeLinked` false or omitted | `searchNotes` | unchanged (`searchNotes`) |
| agent `search_notes`, both `include_linked` values | D4 routing | `retrieveNotes(query:tagFilter:notebookId:includeLinked:depth: 1:limit:offset: 0)` |
| `AIAgenticSearch` grounding | per-term `searchNotes` + RRF | F1 "Agentic grounding" below |
| `kaiba search`, `NoteSearchPopup`, memo search, LTM recall, `noteGraphNeighbors` | FTS / explicit seeds | unchanged |

Answer to the intake question on graph paths: the only query-seeded graph
expansion is `appendLinkedNeighborResults` in `NoteSearch.swift`. GraphQL
`searchNotes`, the agent `search_notes` tool and the agentic full-query
pass all reach it through `searchNotes(includeLinked:)`. The
`noteGraphNeighbors` query and long-term-memory associations start from
explicit note ids, take no query and are unchanged.

The GraphQL engine-failure rule of SE5 ("no silent fallback inside the
server") still holds for `engineSearchNotes` and `relatedNotes`. For
`searchNotes` with `includeLinked: true`, the fallback is silent by
requirement: the result is today's FTS result.

### Agent `search_notes` output

This replaces the D4 routing rule ("routes through the engine only when
`include_linked` is false").

- The tool calls `retrieveNotes` for both `include_linked` values. The
  tool schema text is unchanged.
- `usedSearchEngine == false` (no engine, engine error, empty query, deep
  window): the output is exactly today's FTS output, including
  `"retrieval": "full-text"`, and no new key.
- `usedSearchEngine == true`: every existing key is kept with its
  current meaning (`query`, `results[].note_id`, `notebook_id`, `title`,
  `snippet`, `updated_at`, `term_coverage`, `is_linked_neighbor`,
  `tags`), `"retrieval": "search-engine"` (the engine was queried and
  fused with full-text), and one additive per-result key:
  `"provenance": {"sources": [...], "reasons": [...]}` with the F2
  vocabulary.

### Agentic grounding

`AIAgenticSearchService.search` keeps its prompt, memo pass and context
format. Only the note grounding changes when an engine is attached:

1. The terms are today's `grepTerms(from:)` (full query first, at most 6).
2. For each term in order, call `retrieveNotes(query: term, notebookId:,
   includeLinked: index == 0, depth: 1, limit:)`.
3. If any call returns `usedSearchEngine == false` while an engine is
   attached (an engine failure), discard the pass and run today's
   `groundingResults(query:terms:notebookId:limit:service:)` unchanged
   (invariant 2). Once a failure is seen, no further engine call is made
   in this grounding pass.
4. Otherwise fuse the per-term direct lists with
   `NoteRetrievalReranker.fuse`, the same weights as today (full query
   2.0, each further term 1.0), `limit`. The term lists after the first
   carry the label `agent-query`. Graph neighbors of the full-query call
   form the "Related notes" section exactly as today (neighbors already in
   the matches are dropped, at most `limit`).
5. Each fused match carries the merged provenance of its term results
   plus the `agent-query` label. `grepContextMarkdown` appends
   ` [sources: <sources>; reasons: <reasons>]` (the reasons part omitted
   when empty) to a "Note matches" or "Related notes" line only when the
   result carries provenance, which happens only in this mode, so the
   FTS context text is unchanged.

With no engine, step 2 is not taken: `groundingResults` runs as today. Its
RRF moves onto `NoteRetrievalReranker.fuse` with FTS-only lists, which
yields the same order (F2 rule 5); the existing
`NoteRetrievalFusionTests` grounding assertions must pass unchanged.

The server's GraphQL `agenticSearch` service shares the runtime slot, so
it sees the attached engine. `kaiba ai search` runs in the CLI, which
never builds an adapter (SE2), so it stays on FTS.

### Health and per-call cost

- "Enabled" means an adapter is attached to the slot (D5). There is no
  per-call health probe and no cached health state: a probe would add a
  network round trip to every search and could still race with an
  outage. A thrown engine error is the unhealthy signal, per call.
- An unreachable engine costs at most one failed engine request per
  `retrieveNotes` call and per agentic grounding pass, bounded by the
  adapter's `requestTimeoutSeconds` (D5, default 10). A cross-call circuit
  breaker is recorded as an open question.
- Candidate bounds: engine list at most 200, FTS list at most the window
  (at most 1000 in fused mode), seeds at most 20, neighbors bounded by the
  existing `NoteGraphPolicy` limits, final size `window`. Agentic
  grounding makes at most 6 engine requests per pass.

## F2. Unified reranker

New file `Sources/AppCore/NoteRetrievalReranker.swift`. It is pure: no
database, no network, no LLM, no dependence on dictionary iteration
order.

### Types

```swift
public enum NoteRetrievalSource: String, CaseIterable, Sendable {
  case searchEngine = "search-engine"
  case fullText = "full-text"
  case agentQuery = "agent-query"
  case graphNeighbor = "graph-neighbor"
}

public struct NoteRetrievalProvenance: Equatable, Sendable {
  public var sources: [NoteRetrievalSource]      // fixed order above, unique
  public var reasons: [SearchEngineHitReasonKind] // declaration order, unique
}

enum NoteRetrievalTier: Sendable { case direct, neighbor }

struct NoteRetrievalCandidateList {
  var label: NoteRetrievalSource?   // added to every entry's sources
  var weight: Double
  var tier: NoteRetrievalTier
  var entries: [(noteId: NoteID, provenance: NoteRetrievalProvenance)]
}

struct NoteRetrievalFusedCandidate: Equatable {
  var noteId: NoteID
  var score: Double
  var tier: NoteRetrievalTier
  var provenance: NoteRetrievalProvenance
}

enum NoteRetrievalFusionPolicy {
  static let k = NoteSearchFusionPolicy.reciprocalRankK      // 60
  static let maximumLists = 16
  static let maximumCandidatesPerList = 1000
  static let maximumEngineCandidates = 200
  static let maximumFusedWindow = 1000
}

enum NoteRetrievalReranker {
  static func fuse(_ lists: [NoteRetrievalCandidateList], limit: Int) -> [NoteRetrievalFusedCandidate]
}
```

`NoteSearchResult` gains `public var provenance: NoteRetrievalProvenance?`
with an init default of `nil`. Only F1's fused path sets it, so every
existing FTS result and every existing equality assertion is unchanged.

### Rules

1. At most `maximumLists` lists are used, in the given order; each list
   is truncated to `maximumCandidatesPerList` entries, then to its first
   occurrence of each note id.
2. Score: `score(n) = sum over lists L containing n of weight(L) / (k +
   position_L(n))`, 1-based positions. This is the existing
   `reciprocalRankFusion` convention (RF2, RF5) and is computed with it.
3. Tier: a note is `direct` if it occurs in any direct list, otherwise
   `neighbor`. A neighbor list entry whose note is direct contributes
   nothing (RF3: a neighbor never displaces a direct hit).
4. Order: direct tier first; within a tier, score descending, then note id
   ascending. The output is truncated to `limit`.
5. Reduction property (tested): a single non-empty list yields its own
   order, because the RRF score strictly decreases with position. For
   several FTS-only lists with today's grounding weights, the order equals
   today's `groundingResults` order (score descending, then note id).
6. Provenance: the union of each contributing entry's provenance and each
   contributing list's label, normalized to the fixed orders above.
7. Engine reasons come from `SearchEngineHit.reasons` (D2, D3 kinds).
   Full-text and graph entries carry no reasons.

### Weights (documented constants)

| level | list | weight | rationale |
| --- | --- | --- | --- |
| per query (F1 step 5) | `full-text` direct list | 1.0 | Two independent lexical retrievers get equal votes; a note both rank high rises. |
| per query | `search-engine` direct list | 1.0 | Same. Ontology expansion is already inside the engine list (D2 boosts, or F3 sub-query fusion). |
| per query | `graph-neighbor` neighbor list | 1.0 | Neighbor tier only; with one neighbor list the weight cannot change the order. |
| grounding (F1) | full-query list | 2.0 | Unchanged from RF5. |
| grounding | each further term list (`agent-query`) | 1.0 | Unchanged from RF5. |

Coverage convention: RF2's coverage-first order stays inside the FTS list,
and RF5's multi-list support (a note matched by more lists scores higher)
is how coverage enters fusion. Coverage is not a separate sort key across
sources, because the engine ranks partial matches itself and a tag-only
expansion hit has no text coverage. `termCoverage` is still reported.

Related-notes signals are not a default input of any F1 path: those paths
have no source note. The Meilisearch adapter uses `fuse` internally to
combine its related-notes and expansion sub-queries (F3), so the same
implementation and weights convention covers them.

### GraphQL and KaibaClient (additive)

```graphql
type NoteRetrievalProvenance { sources: [String!]!, reasons: [String!]! }
type NoteSearchResult { note: Note!, snippet: String!, rank: Float!, matchedTags: [NoteTag!]!, isLinkedNeighbor: Boolean!, termCoverage: Float!, provenance: NoteRetrievalProvenance! }
```

- `GraphQLNoteSearchResultDTO` gains `provenance`. When the AppCore value
  is nil (every FTS result), the DTO derives `sources: ["graph-neighbor"]`
  for a linked neighbor and `["full-text"]` otherwise, with `reasons: []`.
  The field is non-null and only returned when selected, so existing
  responses are byte-identical.
- The type and field are registered in the schema contract
  (`GraphQLNoteSchemaContract.swift`) and `noteGraphQLSelectionFields`,
  and covered by the schema inventory test.
- KaibaClient `NoteSearchResult` gains `provenance` (decoded with
  `decodeIfPresent`, optional) and the `searchNotes` selection requests
  `provenance { sources reasons }`.
- The web client does not request or render provenance in this change.

## F3. Meilisearch adapter

### Engine choice

| need | Meilisearch | Typesense | Manticore Search |
| --- | --- | --- | --- |
| runtime | Rust single binary, small container, memory-mapped LMDB store; no JVM | C++ single binary; the whole index is held in RAM | C++ daemon; disk-backed tables, low RAM |
| Japanese/CJK | Built-in segmentation (charabia) with Japanese support; `localizedAttributes` and the search `locales` parameter force Japanese for Han text | Per-field `locale` setting for Japanese | Han text through n-gram (`ngram_chars`) unigrams; no Japanese morphology in the stock build |
| keyword-array filters | yes (`IN`, `=`, `AND`/`OR`/`NOT`) on filterable string arrays | yes on `string[]` | yes on multi-value attributes / JSON |
| facets | `facets` -> `facetDistribution` | yes | yes (`FACET`) |
| highlight / snippet | `attributesToHighlight`, `attributesToCrop`, configurable tags | yes | `highlight()` |
| pagination, delete by id, bulk upsert | yes; writes are asynchronous tasks with batch-level status | yes; JSONL import with per-line results | yes; `/bulk` with per-item results |
| relevance score | `_rankingScore` (0..1) with `showRankingScore` | `text_match` | BM25-based `weight()` |
| `more_like_this` | no | no | no |
| per-clause boosts | no (ranking rules and attribute order only) | per-field weights only | per-field weights only |
| auth | optional key (`Authorization: Bearer`) | API key always required | none by default |

Decision: **Meilisearch**. Japanese quality is the deciding need for
kaiba, and Meilisearch is the only candidate with built-in Japanese
segmentation in its stock image. Its gaps (no `more_like_this`, no
per-clause boosts, task-level write status, a 1000-hit default window)
are all handled inside the adapter below. Typesense was rejected because
it keeps the full index in RAM and always requires an API key, which
complicates the keyless local compose case. Manticore was rejected
because its stock CJK handling is n-gram only, which is weaker than the
existing Elasticsearch `cjk` bigrams for Japanese.

The vendor facts above are recorded from the vendors' documentation. The
live suite (F5) is the acceptance gate: a Japanese query must find a
Japanese note in the pinned stock image. If it does not, the
implementation stops and records a blocker in
`design-docs/user-qa/search-engine-adapter.md`; it does not switch
engines on its own.

### Files and transport

- `Sources/AppCore/MeilisearchSearchEngine.swift`: the `SearchEngine`
  conformance, health, `ensureIndex`, `apply` and task waiting.
- `Sources/AppCore/MeilisearchRequestBodies.swift`: index settings,
  document JSON, filter-expression builder, search and multi-search
  bodies, salient-term extraction.
- `Sources/AppCore/MeilisearchResponses.swift`: response and error
  parsing.
- The HTTP transport becomes adapter-neutral: the protocol, the
  URLSession transport and the single-host trust delegate move unchanged
  from `ElasticsearchHTTPTransport.swift` to the new
  `SearchEngineHTTPTransport.swift` as `SearchEngineHTTPTransport` and
  `URLSessionSearchEngineTransport`. `ElasticsearchHTTPTransport.swift`
  keeps `typealias ElasticsearchHTTPTransport = SearchEngineHTTPTransport`
  and `typealias URLSessionElasticsearchTransport =
  URLSessionSearchEngineTransport`, so Elasticsearch files and tests
  compile unchanged and send identical requests.
- No new SwiftPM dependency. SHA-256 (below) uses the existing
  CryptoKit / swift-crypto import pattern of `KaibaJWT.swift`.

### Index and identity

- Index uid `<indexPrefix>-notes-v1`, primary key `id`.
- `indexIdentity` = `meilisearch:<normalizedTarget>/<indexUid>`, built
  with `SearchEngineFactory.normalizedTarget`, the same shape as
  Elasticsearch's `elasticsearch:<target>/<index>`. The kind prefix is
  already part of every identity, so switching adapters changes the
  identity and triggers the SE3 backfill, while existing Elasticsearch
  identities do not change and cause no re-backfill.
- Document id: the note id when it matches `^[A-Za-z0-9_-]{1,511}$`
  (every minted id, `note-<ms>-<uuid>`, does); otherwise `x-` followed by
  the lowercase hex SHA-256 of the UTF-8 note id. The same mapping is used
  for upsert and delete. The raw id is stored in `note_id`, and hits are
  read from `note_id`.

### Document

The `SearchIndexDocument` fields map one to one onto the D1 Elasticsearch
names: `note_id`, `notebook_id`, `library_id`, `owner_user_id` (null when
absent), `title`, `body`, `tags` (the tag names), `context`, `tag_ids`,
`path_tag_ids`, `path_tag_names`, `tag_classes`, `class_tag_keys`,
`tag_provenance_keys`, `outgoing_link_note_ids`, `incoming_link_note_ids`,
`long_term_memory`, `created_at`, `updated_at`.

### Index settings (applied by `ensureIndex`)

- `searchableAttributes`: `title`, `tags`, `body`, `context`, in this
  order, so the attribute ranking rule mirrors the FTS weights 3/2/1/1.
- `filterableAttributes`: `note_id`, `notebook_id`, `library_id`,
  `owner_user_id`, `tag_ids`, `path_tag_ids`, `tag_classes`,
  `class_tag_keys`, `outgoing_link_note_ids`, `incoming_link_note_ids`,
  `long_term_memory`.
- `sortableAttributes`: `updated_at`.
- `rankingRules`: the Meilisearch default.
- `localizedAttributes`: `title`, `tags`, `body`, `context` with locale
  `jpn` (see user-qa). Latin text is unaffected.
- `pagination.maxTotalHits`: 2000, above the largest SE4 fetch window
  (1000 + 200 + 20).
- `faceting.sortFacetValuesBy`: count for all facets;
  `faceting.maxValuesPerFacet`: 100.

### Protocol operations

- **`health()`**: `GET /health`. `{"status":"available"}` gives
  `isAvailable: true`; any other status or error gives `false` or the
  mapped error, with `detail` the status word.
- **`ensureIndex()`**: `GET /indexes/<uid>`; on 404 `POST /indexes`
  with `{uid, primaryKey: "id"}` and wait for the task; a task error
  `index_already_exists` counts as success. Then always
  `PATCH /indexes/<uid>/settings` with the settings above and wait, so a
  creation interrupted before its settings is repaired on the next call.
  Idempotent.
- **Task waiting**: poll `GET /tasks/<taskUid>` with a backoff from 50 ms
  to 1 s until `succeeded`, `failed` or `canceled`, bounded by
  `max(30, requestTimeoutSeconds)` seconds. Timeout throws
  `.unavailable("task pending")`; the outbox retries, and upserts and
  deletes are idempotent. Writes are searchable once their task has
  succeeded, so there is no refresh step.
- **`apply(_:)`**: upserts in one
  `POST /indexes/<uid>/documents?primaryKey=id` (JSON array) and deletes in
  one `POST /indexes/<uid>/documents/delete-batch` (array of mapped ids),
  each followed by a task wait. Outcomes, in input order:
  - a succeeded task: every operation of that task `.succeeded` (deleting
    an absent document succeeds);
  - a failed upsert task whose error code starts with `invalid_document`
    and that held more than one document: the upserts are resubmitted once,
    one document per task, and each gets its own outcome, so one bad
    document cannot block a batch;
  - any other failed task: every operation of that task
    `.failed("<code>: <message>")`, truncated to 500 characters.
  HTTP 401/403 throws `.rejected`; 5xx and transport errors throw
  `.unavailable`, matching SE8.
- **`search(_:)` and `searchPage(_:)`**: `POST /indexes/<uid>/search`
  with `q`, `filter`, `offset`, `limit`, `showRankingScore: true`,
  `matchingStrategy: "last"`, `locales: ["jpn"]`,
  `attributesToRetrieve` limited to the fields needed for `note_id` and
  the snippet, `attributesToCrop` on `body` and `title` with crop length
  24, and empty highlight tags and crop marker so `_formatted` text is
  plain. The highlight is the cropped `body` when it contains a match,
  otherwise the cropped `title`, trimmed and capped at 200 characters.
  The score is `_rankingScore`; reasons are `[text-match]`.
- **Filter expression** (built from `SearchEngineFilter`, ANDed):
  `library_id IN [...]` (when non-nil), `owner_user_id = "..."`,
  `notebook_id = "..."`, `tag_ids IN [...]`, `path_tag_ids IN [...]`
  (hierarchy ids), per class filter `tag_classes = "c"` or
  `class_tag_keys = "c:t"`, `long_term_memory = false` when excluded,
  `NOT note_id IN [...]` for excluded ids. Every value is a double-quoted
  string with `\` and `"` escaped.
- **Facets**: `facets: ["tag_classes", "tag_ids"]` on the text query; the
  `facetDistribution` buckets are sorted by count descending then value
  and truncated to `tagClassLimit` / `tagLimit`. The service hydration of
  D2 is unchanged.

### Capability gaps, handled in the adapter

No capability flag is added to the protocol: every gap is closed inside
the adapter, so callers and the Elasticsearch adapter are untouched.

- **Ontology expansion without clause boosts.** When `expansionTagIds`
  is non-empty, one `POST /multi-search` runs three queries with the same
  base filter, each fetching `from + size` hits:
  - `text-match`: the text query above;
  - `tag-match`: `q: ""`, filter `AND tag_ids IN expansion`, sorted by
    `updated_at:desc`;
  - `tag-hierarchy-match`: `q: ""`, filter `AND path_tag_ids IN
    expansion`, sorted by `updated_at:desc`.

  The lists are fused with `NoteRetrievalReranker.fuse` (direct tier),
  weights text 1.0, tag 1.0, hierarchy 0.5. A note tagged directly with a
  matched tag also appears in the hierarchy list, so it outranks a
  descendant-tagged note, and a tag-only note at the top of both tag
  lists (1.5 / 61) outranks the top text-only note (1.0 / 61), the D2
  ordering intent. Each hit's reasons are the lists that contained it.
  The page is the fused slice `[from, from + size)`, the score is the
  fused score, and the highlight comes from the text query. Facets come
  from the text query only; D2 already presents facets as refinement
  hints.
- **Related notes without `more_like_this`.** One multi-search runs, each
  query with the base filter and `NOT note_id IN [source]`:
  - `text-similarity`: `q` = the salient terms of `likeText` (skipped when
    blank). Salient terms: the `ftsTerms` runs of the text, case-folded,
    at least 2 characters, ordered by frequency descending then first
    occurrence, at most 10 (Meilisearch uses only the first 10 query
    words);
  - `shared-tag`: `tag_ids IN S`;
  - `related-tag`: `(path_tag_ids IN S union P OR tag_ids IN A)`;
  - `shared-entity`: `class_tag_keys IN E` as `"<class>:<tagId>"`;
  - `linked`: `(outgoing_link_note_ids = "<source>" OR incoming_link_note_ids = "<source>")`.

  Lists for empty signal sets are skipped; with `signals == nil` only the
  text list runs (the base behavior). The lists are fused with
  `NoteRetrievalReranker.fuse` with the D3 boosts as weights: linked 5.0,
  shared-tag 3.0, shared-entity 2.0, related-tag 1.5, text-similarity 1.0.
  Reasons are the lists that contained the hit, and the service's D3
  store enrichment of shared-tag names is unchanged.
- **Hit window.** `maxTotalHits` 2000 covers the SE4 window.
- **Scores.** `NoteEngineSearchHit.score` stays "higher is better, scale
  specific to the adapter". F2 uses ranks only, so scales never mix.

### Errors and secrets

Meilisearch error bodies `{message, code, type}` map to
`"<code>: <message>"`, truncated to 200 characters. Messages never contain
headers, the API key or URL userinfo (SE1).

## F4. Configuration and settings

- `SearchEngineFactory.adapters` appends
  `SearchEngineAdapterDescriptor(kind: "meilisearch", displayName: "Meilisearch", authModes: [.none, .apiKey])`.
  The web settings select, the GraphQL settings read and kind validation
  already derive from this list.
- `make(settings:secret:transport:)` dispatches on `kind`:
  `elasticsearch` builds the unchanged Elasticsearch adapter;
  `meilisearch` builds the Meilisearch adapter with
  `Authorization: Bearer <secret>` for `apiKey` and no header for `none`.
- New factory rule: `authMode` must be one of the descriptor's
  `authModes`, otherwise `invalid("searchEngine.authMode")`
  (`invalid-settings` with that field through D5). Elasticsearch accepts
  all three modes, so its behavior is unchanged.
- Config section: `kind: "meilisearch"` is accepted.
  `apiKeyEnvironmentVariable` names the key. Username or password
  environment variables with this kind throw
  `invalid("searchEngine.credentials")`.
- URL, prefix, TLS, timeout and secret validation, the secret binding to
  `{authMode, target}`, the config-file lock, the admin gate, test
  connection (`health()` only), the `SearchEngineSlot` hot-swap, the
  runtime controller, the outbox, activation and backfill are reused with
  no change. Switching between adapters goes through the D5 reload: the
  old sync loop stops, the new adapter attaches, `ensureIndex` and
  activation run, and the changed identity enqueues every note.
- Switching back to a previously used adapter backfills it again (its
  identity differs from the stored one). Documents of notes deleted in the
  meantime may remain in that index; the SE4 re-check makes them harmless,
  as for any orphaned document.
- The web settings form needs no code change: it already limits the
  auth-mode select to the adapter's `authModes` and shows the username
  only for `basic`. One integration test case covers a Meilisearch
  descriptor (`none`/`apiKey` only; no username field).
- README guidance: for a remote Meilisearch, use an API key restricted to
  the kaiba index pattern and the actions the adapter needs (search,
  documents add/delete, indexes create/get, settings update, tasks get),
  not the master key.

## F5. Local development and live suite

- **Compose file** `docker/meilisearch/compose.yaml`, one service:
  - image `getmeili/meilisearch:v1.<minor>.<patch>`, pinned to a release
    that supports `localizedAttributes`, the search `locales` parameter
    and `showRankingScore` (v1.10 or later); the implementer verifies the
    tag pulls and records it, as SE9 did for Elasticsearch;
  - `MEILI_ENV=development` and `MEILI_NO_ANALYTICS=true`, with no master
    key: local use only, stated in a comment and in the README;
  - port `127.0.0.1:7700:7700`, loopback only;
  - named volume `kaiba-meilisearch-data` at `/meili_data`;
  - a healthcheck on `/health`.
- **mise tasks**, consistent with `search:*`:
  - `search:meilisearch:up` (depends on `search:docker`, which starts
    colima on macOS when Docker is down) runs
    `docker compose -f docker/meilisearch/compose.yaml up -d --wait`;
  - `search:meilisearch:down` runs `down` and keeps the volume;
  - `search:meilisearch:status` runs
    `curl -fsS http://127.0.0.1:7700/health`;
  - `search:meilisearch:test-live` (depends on `anydoc:native` and
    `search:meilisearch:up`) runs
    `KAIBA_MEILISEARCH_URL=${KAIBA_MEILISEARCH_URL:-http://127.0.0.1:7700} swift test --filter MeilisearchLive`
    with the same `PKG_CONFIG_PATH` env as `search:test-live`.
- **Live suite** `Tests/AppCoreTests/MeilisearchLiveTests.swift`, skipped
  unless `KAIBA_MEILISEARCH_URL` is set, using a unique `indexPrefix` per
  run and deleting its index when done:
  - `ensureIndex` twice, then upsert English, Japanese and related
    documents;
  - an English query and a Japanese query (`東京` finds `東京の天気`);
  - ontology: a descendant-tag filter, a class filter, a tag-only
    expansion hit ranked above a text-only hit, facets returned;
  - related notes: linked, then shared-tag, then text-only, with the
    expected reason kinds, and the source never returned;
  - delete by id;
  - service level: store settings with kind `meilisearch`, activation and
    backfill drain, then `retrieveNotes(includeLinked: true)` returns an
    engine-only seed's linked neighbor with provenance `search-engine`.

## F6. Documentation

- `README.md`: an "Optional search engine" subsection on choosing an
  engine (Elasticsearch: JVM, 512 MB heap in the local compose, `cjk`
  bigrams, `more_like_this`; Meilisearch: single Rust binary, no JVM,
  Japanese segmentation, related notes composed in kaiba), the
  Meilisearch config sample, the `search:meilisearch:*` tasks, the
  restricted API key advice, and engine-seeded graph and agent search with
  the FTS fallback.
- `design-docs/specs/command.md` ("Search engine"): the adapter kinds.
- `design-docs/specs/search-engine-adapter.md` and
  `note-retrieval-fusion.md`: pointers to this design and the changed
  base rules.

## Changed base rules

- SE1 "Out of scope": "other engines" and "feeding engine hits into the
  FTS fusion ranking" are replaced by F3 and F1/F2.
- SE5 "`searchNotes` is unchanged": now holds for `includeLinked` false or
  omitted. With `includeLinked: true` and an attached engine, F1 applies.
- D4 agent routing: replaced by F1 "Agent `search_notes` output". The D4
  test `testIncludeLinkedKeepsFullTextRouting` encodes the replaced rule
  and is replaced by an F1 test (the engine is used with
  `include_linked: true`). The other D4 routing tests keep passing.
- D4 "`AIAgenticSearch` grounding stays on FTS": replaced by F1
  "Agentic grounding".
- SE8 "Elasticsearch adapter ... `Sources/AppCore/Elasticsearch*.swift`":
  the transport implementation moves to `SearchEngineHTTPTransport.swift`
  behind type aliases; Elasticsearch requests are unchanged.
- RF3/RF5 seeding: with an engine attached, seeds and grounding lists come
  from F2 fusion; without one, RF3/RF5 hold exactly.

Unchanged: the outbox and drain (SE3), two-stage access control (SE4),
`engineSearchNotes`, `relatedNotes`, facets and reasons (D2, D3), the
settings and hot-swap (D5), store schema version 23, and every FTS stage
(RF1, RF2, RF4).

## Test plan

- **AppCore `NoteRetrievalRerankerTests`** (pure): single-list
  order preservation; weighted RRF; ties by note id; deduplication;
  direct-before-neighbor and a neighbor entry of a direct note ignored;
  provenance union and normalization; list and candidate caps; the
  grounding-equivalence case against today's `groundingResults` order.
- **AppCore `EngineSeededRetrievalTests`** (`FakeSearchEngine`, which
  ignores filters):
  - no engine: `retrieveNotes` equals `searchNotes` for `includeLinked`
    true and false, with tag, class, date and notebook filters, and
    `usedSearchEngine` is false;
  - engine error: same equality, and no partial engine contribution;
  - an engine-only hit seeds PPR: its linked neighbor appears with
    `isLinkedNeighbor` and `graph-neighbor` provenance;
  - the re-check drops engine hits from an unreachable library, another
    owner, long-term memory, a pending ingest, a tag, class or date filter
    mismatch, and deleted notes;
  - fused order, `rank`, snippet and coverage rules, provenance sources
    and reasons;
  - the engine request size is `min(window + 20, 200)`; a window above
    1000, an empty query and `limit == 0` make no engine call;
  - `reachableLibraryIds == []` makes no engine call.
- **AppCore `AgentSearchNotesFusionTests`**: `include_linked` true and
  false use the engine; output keys are unchanged, `retrieval` is
  `search-engine`, and `provenance` is present; with no engine or an
  engine error the JSON equals today's (`retrieval: full-text`, no
  `provenance` key). `AgentSearchNotesRoutingTests` keeps every test
  except `testIncludeLinkedKeepsFullTextRouting`, which this file
  replaces.
- **AppCore `AgenticGroundingEngineTests`**: engine attached: per-term
  engine queries are recorded, grounding uses fused lists, and context
  lines carry the sources suffix; any engine failure yields exactly the
  FTS grounding and context; no engine: the existing
  `NoteRetrievalFusionTests` grounding tests pass unchanged.
- **AppCore `MeilisearchSearchEngineTests`** (mock transport): exact
  method, path and body for health, `ensureIndex` (absent, present,
  already-exists), settings, upsert and delete batches, task polling and
  timeout, per-document resubmission after an `invalid_document` failure,
  search and filter escaping, the expansion and related multi-search with
  fused order and reasons, facets, error mapping, the auth header for
  `none` and `apiKey`, the non-charset id mapping, and no secret in any
  error.
- **AppCore factory and settings tests**: the descriptor list; `basic`
  rejected for Meilisearch with `searchEngine.authMode`; config
  credentials rules for Meilisearch; the Elasticsearch identity string is
  unchanged; Meilisearch identity format.
- **AppServer `SearchEngineRuntimeControllerTests`**: a reload from an
  Elasticsearch fake to settings of kind `meilisearch` swaps the adapter
  seen by a scoped copy and backfills on the identity change.
- **AppGraphQL**: `searchNotes(includeLinked: true)` with an engine routes
  through `retrieveNotes`; `includeLinked: false` makes no engine call;
  `provenance` is in the schema inventory; derived provenance for FTS
  results.
- **KaibaClient**: the `searchNotes` selection and model decode
  `provenance`.
- **Web**: `SearchEngineSettings.integration.tsx` covers a Meilisearch
  descriptor. Existing web tests pass unchanged.
- **Live**: `ElasticsearchLiveTests` unchanged and `MeilisearchLiveTests`
  (F5).

The existing `NoteSearch*`, `NoteRetrievalFusionTests`,
`KaibaAgentToolboxTests`, `ElasticsearchSearchEngineTests` and
`ElasticsearchLiveTests` pass without modification.

## Verification

Gate-compatible evidence follows "Delta verification" in
`search-engine-adapter.md`: each behavioral record is a test-runner
command with exit code 0, every count greater than 0, the complete log
path and the final exit status.

- `mise run build`
- `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test`
- `mise run lint`
- `cd web && mise exec -- bun test src` (bun count > 0) and
  `cd web && mise exec -- bunx vitest run` (vitest count > 0), recorded
  separately; then `mise run web:check` (writes `web/dist`, which every
  plan running it declares as an artifact root).
- `mise run tauri:check` (macOS, local only).
- `mise run search:test-live` and `mise run search:meilisearch:test-live`:
  record only the XCTest `Executed N tests, 0 failures` line with N > 0.
  An env-gated skip is never a verification record.
- Boundary grep, expected to return nothing:
  `grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+SearchEngine*.swift Sources/AppCore/NoteService+EngineSeededRetrieval.swift Sources/AppCore/NoteRetrievalReranker.swift Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift Sources/AppCore/Meilisearch*.swift`
- `wc -l` on every touched Swift file: each is under 1000 lines
  (`NoteSearch.swift` is 876 and only changes one access modifier).

## Rollout

- **No engine configured:** no behavior change. GraphQL gains an
  additive field.
- **Existing Elasticsearch deployments:** the identity is unchanged, so
  there is no backfill. Graph search, the agent tool and agentic
  grounding start using engine seeds at once, and fall back to FTS on any
  engine error.
- **Switching to Meilisearch:** through the config file (restart) or the
  settings UI (hot-swap). The new identity backfills through the outbox;
  until the drain completes, fused results simply include fewer engine
  hits, because the FTS list is always fused in.
- **Store schema:** unchanged (version 23).

## Plan partition guidance (for the plan author)

Boundaries, not binding plan ids. AppCore is one compile unit, so shared
files have one owner per wave.

- **Wave 1, contract:** `NoteRetrievalReranker.swift` with its tests, the
  `NoteSearchResult.provenance` field, `appendLinkedNeighborResults`
  made internal, and the transport move to
  `SearchEngineHTTPTransport.swift`.
- **Wave 2, parallel:**
  - F1 service: `NoteService+EngineSeededRetrieval.swift` and its tests;
  - F3/F4 adapter: `Meilisearch*.swift`, the factory dispatch,
    descriptor and auth-mode rule, and the mock-transport, factory and
    settings tests.
- **Wave 3, parallel after their dependencies:**
  - agent tool and agentic grounding (`KaibaAgentToolbox.swift`,
    `AIAgenticSearch.swift`; after F1);
  - GraphQL routing and provenance plus KaibaClient (after F1);
  - runtime-controller test, compose, mise tasks and the live suite
    (after F3);
  - web settings test (declares `web/dist` as an artifact root);
  - README and command docs.
- **Wave 4:** integration, which owns cross-plan compile and lint fixes
  and runs the full verification set, including both live suites.

`impl-plans/active/search-engine-adapter-dispatch.json` and
`impl-plans/active/note-retrieval-fusion.md` stay where they are as the
records of earlier work. The plans for this design get their own files
and dispatch manifest.
