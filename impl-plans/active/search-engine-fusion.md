# Search Engine Fusion and Meilisearch Adapter (index)

**Status**: In Progress (plans created 2026-10-05)
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` (F1-F6)
**Related designs**: `design-docs/specs/search-engine-adapter.md`, `design-docs/specs/note-retrieval-fusion.md`, `design-docs/user-qa/search-engine-adapter.md`
**Evidence root**: `tmp/search-engine-fusion/<planId>/` (gitignored; each plan writes only its own directory)

## Purpose

When a search engine is attached, kaiba should use engine hits to seed graph
search, the agent `search_notes` tool and agentic grounding. One
deterministic reranker should fuse engine, full-text, agent-query and
graph-neighbor candidates. A lightweight Meilisearch adapter should be
selectable in settings and runnable locally. With no engine attached, every
path behaves exactly as it does today.

## Plans and waves

| wave | planId | plan | dependsOn |
| --- | --- | --- | --- |
| 1 | P1-fusion-contract | `impl-plans/active/search-engine-fusion-p1-contract.md` | none |
| 1 | P8-web-settings-test | `impl-plans/active/search-engine-fusion-p8-web-settings-test.md` | none |
| 2 | P2-engine-seeded-retrieval | `impl-plans/active/search-engine-fusion-p2-engine-seeded-retrieval.md` | P1 |
| 2 | P3-meilisearch-adapter | `impl-plans/active/search-engine-fusion-p3-meilisearch-adapter.md` | P1 |
| 3 | P4-agent-search-notes | `impl-plans/active/search-engine-fusion-p4-agent-search-notes.md` | P2 |
| 3 | P5-agentic-grounding | `impl-plans/active/search-engine-fusion-p5-agentic-grounding.md` | P2 |
| 3 | P6-graphql-client-provenance | `impl-plans/active/search-engine-fusion-p6-graphql-client-provenance.md` | P2 |
| 3 | P7-docs | `impl-plans/active/search-engine-fusion-p7-docs.md` | P3 |
| 3 | P9-meilisearch-tooling-live | `impl-plans/active/search-engine-fusion-p9-meilisearch-tooling-live.md` | P2, P3 |
| 4 | P10-integration | `impl-plans/active/search-engine-fusion-p10-integration.md` | P1-P9 |

The DAG is P1 -> {P2, P3} -> {P4, P5, P6, P7, P9} -> P10. P8 is
independent and feeds only P10. P7 is the only `README.md` writer in
wave 3.

## Shared-file ownership

AppCore is a single compile unit, and all plans run on one branch in one
working directory. Each file below has exactly one writer:

- `Sources/AppCore/NoteRetrievalReranker.swift`,
  `Sources/AppCore/NoteModels.swift`, `Sources/AppCore/NoteSearch.swift`,
  `Sources/AppCore/SearchEngineHTTPTransport.swift`,
  `Sources/AppCore/ElasticsearchHTTPTransport.swift`: P1.
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: P2.
- `Sources/AppCore/SearchEngineFactory.swift`, `Sources/AppCore/Meilisearch*.swift`: P3.
- `Sources/AppCore/KaibaAgentToolbox.swift`: P4.
- `Sources/AppCore/AIAgenticSearch.swift`: P5.
- AppGraphQL and KaibaClient files: P6.
- `docker/meilisearch/compose.yaml`, `mise.toml`: P9.
- `README.md`: P7.
- `web/src/components/SearchEngineSettings.integration.tsx`: P8.
- This index: P10 (status and final summary only).

## Edit protocol (every plan)

1. Before each edit, read the target file fresh. Append its `shasum -a 256`
   to `tmp/search-engine-fusion/<planId>/hashes.txt` with a `pre` label.
   After the edit, append the `post` hash.
2. Before the first edit, write a short intent snapshot,
   `tmp/search-engine-fusion/<planId>/intent.md`, listing the files and
   symbols you will change. Do not rewrite it afterwards.
3. Edit only your own `writePaths`. `sharedPaths` are read-only for you.
4. Drift: if a file you own changed between your `post` hash and a later
   `pre` hash, stop and record it in your progress log. Re-read the file
   and re-apply only your intended change.
5. Peer compile or lint failures in files you do not own are not your
   blockers. Record the failing file in your progress log, wait or retry
   after peers land, and leave cross-plan fixes to P10.
6. Never run `git` write operations (commit, checkout, stash, reset). Never
   create worktrees or branches. Do not touch `.riela/`.
7. Each plan updates only its own progress log, in its own plan file.
8. Declarations: every `writePaths` and `sharedPaths` bullet is a single
   bare path. Explanations live in `sharedPathNotes`. `artifactRoots`
   hold only generated output: the evidence logs under
   `tmp/search-engine-fusion/<planId>`, `web/dist` and
   `web/src-tauri/target`. Authored files (sources, tests, compose files,
   `mise.toml`, `README.md`, plan files) are never artifact roots.

## Evidence rules

- A behavioral record is a test-runner command (`swift test ...`,
  `bun test ...`, `vitest run ...`, or `mise run <task containing test>`)
  with `exit=0` and a positive count. For XCTest, record the
  `Executed N tests, 0 failures` line with N > 0.
- Never record an env-gated skip as evidence.
- Report `bun test src` and `vitest run` separately.
- Every command is run through `tee` into the plan's evidence directory.
  Each record gives the complete log path and the final exit status.

## Progress Log

- 2026-10-05: Index and plans P1-P10 created from the accepted design
  (Step 3 accepted, comm-003999).
- 2026-10-05: Revised after the Step 5 review (comm-004001):
  - SEF-PLAN-001: declarations are bare paths, with explicit
    artifactRoots and `web/src-tauri/target` declared in P10; P9 records
    the image digest.
  - SEF-PLAN-002: P3 adds an internal task-wait test seam.
  - SEF-PLAN-003: P7 moves to wave 3 after P3, with a factory test record.
