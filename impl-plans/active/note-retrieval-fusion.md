# Note Retrieval Fusion

**Status**: Implemented (2026-09-03); awaiting field observation of agent search behaviour
**Design Reference**: `design-docs/specs/note-retrieval-fusion.md`

## Purpose

Raise note recall and ranking quality using the techniques selected from the
2024-2026 RAG / GraphRAG survey that need no embedding model: contextual
indexing, relaxed term matching with reciprocal rank fusion, personalized
PageRank over the link and tag subgraph, recency-aware memory recall, and
fused multi-query grounding for the agent.

## Deliverables

- [x] `note_fts` gains a `context` column; schema version 19; weighted bm25
- [x] Staged lexical search with a relaxed RRF stage and `termCoverage`
- [x] PPR re-ranking of graph neighbours in linked search expansion
- [x] `recencyWeight` on `recallLongTermMemories`
- [x] Agentic search grounding fused with RRF; `search_notes` gains
      `include_linked`, `tags`, `term_coverage`, `is_linked_neighbor`
- [x] GraphQL `NoteSearchResult.termCoverage`, CLI JSON and text markers
- [x] Tests for every acceptance item in the design

## Tasks

### TASK-001: Contextual index column (RF1)

**Parallelizable**: No (schema first)

**Completion Criteria**:

- [x] `FTSPayload.context` built from notebook title and tag ancestors
- [x] Create, delete, refresh and rebuild paths pass four columns
- [x] `NoteStoreSchema.currentVersion == 19`
- [x] Test: notebook-title word and ancestor-tag word find the note

### TASK-002: Relaxed matching and RRF (RF2)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `NoteSearchLexicalFusion.swift` with term stage and RRF helpers
- [x] `NoteSearchResult.termCoverage` projected to GraphQL, CLI, tool
- [x] Test: full match precedes partial match; coverage reported

### TASK-003: PPR-fused graph expansion (RF3)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `NoteGraphPersonalizedPageRank.swift` pure routine plus edge loader
- [x] Neighbour order by PPR mass; direct hits unchanged
- [x] Unit test on a hand-built graph; service test with two seeds

### TASK-004: Recency fusion in memory recall (RF4)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `recencyWeight` parameter, default 0.5
- [x] Test: default keeps lexical order; large weight flips

### TASK-005: Agentic grounding and tool inputs (RF5)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `AIAgenticSearchService` fuses lists and labels neighbours
- [x] `search_notes` schema and executor accept `include_linked`, `tags`
- [x] Tests for tool inputs and grounding order

### TASK-006: Verification

**Parallelizable**: No

**Completion Criteria**:

- [x] `swiftlint` clean on touched files
- [x] `swift test` green for AppCore and AppGraphQL

## Progress Log

- 2026-09-03: Plan created from the survey and design.
- 2026-09-03: RF1-RF5 implemented with tests; `swift test` 764 tests green after
  updating one search assertion to the relaxed-matching contract; `swiftlint`
  clean; `bun run check` green for the web partial marker.
