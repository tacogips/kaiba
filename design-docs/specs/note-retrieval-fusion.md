# Note Retrieval Fusion

## Status

Accepted (2026-09-03)

## Traceability

- Survey: `design-docs/references/rag-graphrag-retrieval-survey-2026-09.md`
  (42 papers, 2024 to 2026). Paper numbers below (`[n]`) refer to that table.
- Predecessors: `design-docs/specs/kaiba-note.md` (search and graph traversal),
  `design-docs/specs/ai-agent-integration.md` (agentic search, AI1),
  `design-docs/specs/user-agent-tools.md` (UA4 `search_notes`),
  `design-docs/specs/library.md` and `design-docs/specs/multi-user.md`
  (scope rules consumed unchanged).
- Implementation plan: `impl-plans/active/note-retrieval-fusion.md`.

## Problem

Kaiba retrieves notes with one SQLite FTS5 trigram index and a bounded
best-first walk over explicit links and shared tags. Measured against the
current RAG and GraphRAG literature, four things limit recall and ranking:

1. **All-or-nothing term matching.** A query is one FTS `MATCH` that ANDs every
   term. A note that contains two of three query words is never returned; the
   only fallback is a substring scan of the whole query string.
2. **Context-free indexing.** Only the note's own title, body and direct tag
   names are indexed. A note whose meaning comes from its notebook ("Kubernetes
   migration" / "step 3: drain nodes") or from a parent tag is invisible to a
   query that uses the notebook or parent-tag vocabulary.
3. **Seed-blind graph expansion.** `includeLinked` appends neighbours ranked by
   the best single path from any direct hit. Every seed counts the same
   regardless of its lexical rank, and a neighbour reached from three hits is
   scored like one reached from one.
4. **Order-of-arrival grounding.** Agentic search unions per-term hit lists in
   arrival order, so the note matching the most query terms is not
   necessarily first in the grounding document, and the agent's
   `search_notes` tool cannot reach the graph at all.

## Selection

The survey was filtered to techniques that work without an embedding model or
an external vector store, because kaiba ships as a single SQLite-backed binary.
Selected, in priority order:

| id | technique | evidence | expected effect in kaiba |
| --- | --- | --- | --- |
| RF1 | Contextual index column (deterministic breadcrumb) | Contextual Retrieval [18]: contextual BM25 cut top-20 failure 5.7% to 2.9%; BM25-to-CRAG benchmark [31] reports consistent gains from contextual retrieval and BM25 beating a dense model on domain vocabulary | Recall on short notes whose bodies lack the searched words; largest lever without embeddings |
| RF2 | Term-level relaxed matching fused by reciprocal rank fusion (RRF) with coverage | RRF is the default fusion in every 2025-2026 hybrid study surveyed; SmartSearch [36] reaches 93.5% on LoCoMo with lexical recall plus rank fusion; IterKey [25] and LogicalRAG [26] show BM25-only agent loops match hybrid baselines | Fewer total misses on multi-word queries; partial matches ranked below full matches, never instead of them |
| RF3 | Personalized PageRank (PPR) seeded by lexical rank over the note, link and tag subgraph | HippoRAG 2 [2] (damping 0.5, MuSiQue F1 48.6 vs 45.7), LinearRAG [8] (PPR with zero index-time LLM tokens, 2Wiki 63.7 vs 43.0), GraphRAG-Bench [11] (evidence recall 87.91 vs 64.47 on reasoning) | Better neighbour order on associative queries; neutral on direct lookups because direct hits keep their position |
| RF4 | Recency as a minor fusion signal for long-term memory recall | Zep [33] (+18.5% LongMemEval), Engram [37] (recency-aware hybrid read path, 83.6% vs 73.2%); Learning What to Remember [39] shows recency alone is poor (0.368 vs 0.770), so it stays a minor weight | "What is the current state of X" recall over consolidated memories |
| RF5 | Multi-query grounding with RRF and graph reach for the agent | RAG-Fusion [29], DMQR-RAG [28], IterKey [25], EviReform [15]; counter-evidence from the 2026 industry RAG Fusion deployment [30] (gains lost after truncation) bounds the design | The agent's grounding document lists the best-supported notes first, and the tool loop can widen to linked notes on demand |

Rejected for now, with the reason:

- **LLM-built entity graphs** (LightRAG [3], Microsoft GraphRAG [5], KAG [7]):
  index-time cost of tens of millions of tokens on the surveyed corpora and
  100k to 331k tokens per query in GraphRAG-Bench [11]; kaiba's tags and links
  already play the entity role at zero index cost (the LinearRAG [8] and
  E²GraphRAG [9] argument).
- **Proposition or section-level indexing with parent aggregation** (Dense X
  [17], RAPTOR [16], Hierarchical Lexical Graph [10]): the reported gains are
  for dense retrievers; bm25 already length-normalises, and document import
  already maps pages to notes. Revisit if long single notes become common.
- **Learned rerankers, late interaction, learned sparse** (ColBERT, SPLADE,
  jina-reranker): need a model at query time.
- **Bi-temporal validity columns** (Zep, Engram): long-term memory already
  carries `periodStart`/`periodEnd`; invalidation semantics are a product
  question recorded in `design-docs/user-qa/note-retrieval-fusion.md`.

## Design Decisions

### RF1. Contextual index column

`note_fts` gains a fourth column `context` (schema version 19; kaiba carries
no migrations, so an older store is rejected and recreated as usual). The
column holds, space separated and sorted for a stable payload:

- the notebook title;
- the names of every ancestor of every tag on the note (the tag path minus the
  tag itself, which the `tags` column already carries), excluding
  `notebook-kind:*` and system tags.

The payload is deterministic; no LLM situating sentence is generated. Notebook
titles and tag names are immutable in kaiba, so the existing FTS refresh
points (note write, tag apply and remove, undo, rebuild) cover them. A tag can
be reparented through `defineTag`, which changes the ancestry its notes index:
that path re-indexes every note under the moved tag. Because the FTS table is
contentless, a `'delete'` must repeat the exact inserted values, so the
context payload is stored on the `note_fts_map` row and read back from there
rather than re-derived. `FTSPayload` carries `context`; the `'delete'`
command and `rebuildNoteFTS` pass all four columns.

Ranking uses explicit column weights so a title or tag hit outranks a body
hit and a context hit does not swamp the note's own text:

```sql
bm25(note_fts, 3.0, 1.0, 2.0, 1.0)  -- title, body, tags, context
```

### RF2. Term-level relaxed matching with coverage-first RRF

`searchNotesInDatabase` becomes a staged pipeline. Every stage applies the same
notebook, library, owner, long-term-memory, tag, class and date predicates.

1. **Strict stage (unchanged).** One `MATCH` over all query terms; results
   carry `termCoverage = 1.0` and `rank` = bm25.
2. **Relaxed stage.** Runs only when the query has at least two indexable
   terms (three or more Unicode scalars, so the trigram index can match them)
   and the strict stage returned fewer rows than the requested window. Each
   term (at most `NoteSearchFusionPolicy.maximumTerms` = 8) is matched on its
   own, excluding strict hits, at most `perTermCandidateLimit` = 50 rows per
   term. Rows are fused with reciprocal rank fusion, `k` = 60:

   ```
   score(note) = sum over matched terms t of 1 / (k + rank_t(note))
   ```

   Ordered by `termCoverage` (matched terms / indexable terms) descending,
   then fused score descending, then the requested sort clause. `rank` is the
   fused score.
3. **Substring fallback (unchanged).** The `LIKE` scan still runs when both
   stages are empty or the query has a sub-trigram term.
4. **Graph expansion** (RF3).

Strict hits always precede relaxed hits, so every existing ordering
expectation holds. `NoteSearchResult.termCoverage` is new (default 1.0) and is
projected as `termCoverage: Float!` on the GraphQL `NoteSearchResult` type, in
`kaiba search --output json`, and as `term_coverage` in the agent tool result.
The text CLI marks a partial hit with `[partial m%]`.

### RF3. PPR-fused graph expansion

`appendLinkedNeighborResults` keeps the bounded best-first traversal as the
candidate generator (its scope, depth, and eligibility rules are unchanged) and
adds a ranking pass over the induced subgraph:

- **Nodes.** The direct hits used as seeds (at most 20) plus the eligible
  neighbour candidates.
- **Edges.** Explicit links among the nodes (weight 1, both directions) and
  shared non-structural tags among the nodes (weight = the existing
  `sharedTagWeight`, the idf form in `NoteGraphTraversal`, best tag per pair).
  Lexical edges are not rebuilt; the candidate set already reflects them.
- **Personalization.** Seed `i` (0-based position in the direct-hit order)
  receives `1 / (k + i)` with `k` = 60, normalised to sum to 1. Candidates
  receive 0.
- **Iteration.** `p <- d * W^T p + (1 - d) * s` with `d` = 0.5 (HippoRAG 2's
  damping), `W` row-normalised by weighted degree (which is the hub mitigation
  the survey recommends for tag graphs), 20 iterations, `p` renormalised each
  step so dangling nodes do not leak mass.
- **Order.** Neighbours are ordered by PPR mass descending, then traversal
  weight descending, then note id. `rank` on a neighbour result is its PPR
  mass. Direct hits keep their lexical order and position; a neighbour never
  displaces one.

The pure PPR routine lives in `NoteGraphPersonalizedPageRank.swift` and is
unit tested without a database. With a hub node the degree normalisation caps
what a broad tag can move; with a single seed and a single candidate the order
reduces to the previous behaviour.

### RF4. Recency-weighted long-term memory recall

`recallLongTermMemories(query:limit:includeAssociations:associationDepth:recencyWeight:)`
gains `recencyWeight` (default 0.5; 0 disables). Direct hits are collected as
before (bm25 pool of `2 * limit` capped at 100, topped up by the substring
scan), then re-ranked in memory:

```
fused = 1 / (k + lexicalRank) + recencyWeight / (k + recencyRank)
```

`recencyRank` orders the candidate pool by `periodEnd` from the entry's
metadata, falling back to `createdAt`, newest first. `k` = 60. Recency acts
only inside the matched pool; it can reorder near-ties but never introduces a
note the query did not match. With the default weight, a recency gap of one
position cannot overturn a lexical gap of one position (the RRF deltas differ
by a factor of two), which is the "minor signal" behaviour the evidence
supports. `rank` stays the bm25 value so association results keep
`weight == rank`.

### RF5. Agentic search grounding and the `search_notes` tool

`AIAgenticSearchService.search` replaces order-of-arrival union with fusion:

- The full query runs with `includeLinked: true`, depth 1 (weight 2.0 in RRF).
- Each content term (existing `grepTerms`, stop words removed) runs on its
  own (weight 1.0).
- Lists are fused with RRF, `k` = 60; the top `limit` notes form the
  "Note matches" section, graph-only neighbours form a separate "Related notes
  (reached through links or shared tags)" section so the model can tell
  evidence from association. Memo matching is unchanged.

`search_notes` (UA4) accepts two new optional inputs and returns two new
fields:

| input | meaning |
| --- | --- |
| `include_linked` | also return notes linked to or sharing rare tags with the hits (RF3 ordering) |
| `tags` | restrict to notes carrying any of these tag names (hierarchy aware) |

| output field | meaning |
| --- | --- |
| `term_coverage` | 1.0 for a full match, `m/n` for a relaxed match |
| `is_linked_neighbor` | true for a graph neighbour |

The tool description instructs the model to run several focused queries
(synonyms, sub-questions, entity names) rather than one long one, to treat
low `term_coverage` as weak evidence, and to use `include_linked` for
"related to" questions. This is the IterKey / LogicalRAG loop expressed as
guidance; no extra provider round is forced, so simple lookups stay one call
(the Adaptive-RAG caution in the survey).

## Non-goals

- No embedding model, no vector table, no learned reranker.
- No LLM call at index time.
- No change to scope enforcement: every new query path reuses the predicate
  builders in `NoteSearch.swift` and the graph scope filter.
- The GraphQL addition is additive; the web client only reads `termCoverage`
  to show a `partial m%` marker next to the existing `linked` marker.

## Acceptance

- A query naming a notebook title word or an ancestor tag name finds the
  notebook's notes (RF1).
- "alpha beta gamma" returns the note containing all three before a note
  containing two, and the two-term note carries `termCoverage` 2/3 (RF2).
- A neighbour linked to two direct hits outranks one linked to a single,
  lower-ranked hit (RF3); the PPR routine is deterministic and conserves mass.
- Two matching memories keep lexical order at the default weight and flip
  under a large `recencyWeight` (RF4).
- The grounding document lists the note matching the most terms first and
  labels graph neighbours; `search_notes` honours `include_linked` and `tags`
  (RF5).
- Schema version 19 is created fresh and version 18 stores are rejected.
- Behaviour change accepted: a multi-word query now returns notes matching a
  subset of the words after the full matches (`termCoverage` < 1), so callers
  that expected an all-or-nothing result read the coverage field.
