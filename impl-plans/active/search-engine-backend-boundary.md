# Search Engine Backend-Only Boundary (index)

**Status**: In Progress (plans created 2026-10-05, session-272)
**Design Reference**: `design-docs/specs/search-engine-adapter.md` "Delta: backend-only engine boundary (B0-B8)"
**Related designs**: `design-docs/specs/design-search-engine-fusion.md` (Status "Later changes", invariant 7), `design-docs/specs/command.md` ("Search engine"), `design-docs/user-qa/search-engine-adapter.md` ("Backend-only engine boundary (2026-10-05)")
**Evidence root**: `tmp/search-engine-backend-boundary/<planId-prefix>/` (gitignored by `tmp/`; each plan writes only its own directory)

## Purpose

Only the kaiba backend may talk to the search engine. Commit 137c6f7 sent
the server's default engine URL to clients through
`SearchEngineAdapterDescriptor.defaultURL` (AppCore, GraphQL, KaibaClient,
web prefill). These plans remove that field, make the settings URL
optional (omitted, null, empty or whitespace-only = "server default",
resolved on the backend from `KAIBA_MEILISEARCH_URL` and then
`SearchEngineFactory.fallbackMeilisearchURL`), persist a server-default
marker instead of the resolved value, make the settings read return the
explicit URL or `null`, show a `Server default` hint in the web form, and
guard `web/src` against engine coordinates. The design-doc work (audit,
decisions, Elasticsearch historical markers, `command.md`) was done in the
design step; the README paragraph is P4.

## Plans and waves

| wave | planId | plan | dependsOn |
| --- | --- | --- | --- |
| 1 | P1-descriptor-contract | `impl-plans/active/search-engine-backend-boundary-p1-descriptor-contract.md` | none |
| 1 | P3-web-server-default | `impl-plans/active/search-engine-backend-boundary-p3-web-server-default.md` | none |
| 1 | P4-readme | `impl-plans/active/search-engine-backend-boundary-p4-readme.md` | none |
| 2 | P2-backend-resolution | `impl-plans/active/search-engine-backend-boundary-p2-backend-resolution.md` | P1 |
| 3 | P5-integration | `impl-plans/active/search-engine-backend-boundary-p5-integration.md` | P1, P2, P3, P4 |

DAG: P1 -> P2 -> P5; P3 -> P5; P4 -> P5. P3 and P4 never touch Swift.
P1 and P2 are sequenced because both edit
`Sources/AppCore/NoteService+SearchEngineSettings.swift` (P1 changes one
line; P2 rewrites the read and validation paths) and AppCore,
AppGraphQL and KaibaClient form one compile chain.

## Shared-file ownership

Every file has exactly one writer per wave.

| file | wave 1 | wave 2 | wave 3 |
| --- | --- | --- | --- |
| `Sources/AppCore/SearchEngineSettingsTypes.swift` | P1 | - | P5 (repair only) |
| `Sources/AppCore/SearchEngineFactory.swift` | P1 | - | P5 (repair only) |
| `Sources/AppCore/NoteService+SearchEngineSettings.swift` | P1 (adapters line only) | P2 | P5 (repair only) |
| `Sources/AppCore/SearchEngineSettingsResolver.swift` | - | P2 | P5 (repair only) |
| `Sources/AppCore/KaibaConfiguration.swift` | - | P2 | P5 (repair only) |
| `Sources/AppCore/CommandSearchEngine.swift` | - | P2 | P5 (repair only) |
| `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift` | P1 | - | P5 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift` | P1 | - | P5 (repair only) |
| `Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift` | P1 | - | P5 (repair only) |
| `Sources/KaibaClient/KaibaModels+SearchEngine.swift` | P1 | - | P5 (repair only) |
| `Sources/KaibaClient/KaibaOperations+SearchEngine.swift` | P1 | - | P5 (repair only) |
| `Tests/AppCoreTests/SearchEngineFactoryTests.swift` | P1 | - | P5 (repair only) |
| `Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift` (new) | P1 | - | P5 (repair only) |
| `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift` | P1 | - | P5 (repair only) |
| `Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift` | - | P2 | P5 (repair only) |
| `Tests/AppCoreTests/SearchEngineSettingsTests.swift` | - | P2 | P5 (repair only) |
| `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift` | - | P2 | P5 (repair only) |
| `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift` | - | P2 | P5 (repair only) |
| `web/src/notes/types.ts`, `client.ts`, `searchEngineSettings.ts`, `searchEngineSettings.test.ts`, `engineBoundary.test.ts` (new) | P3 | - | P5 (repair only) |
| `web/src/components/SearchEngineSettings.tsx`, `SearchEngineSettings.integration.tsx` | P3 | - | P5 (repair only) |
| `README.md` | P4 | - | P5 (fact corrections only) |
| this index | - | - | P5 |

Files no plan may edit: `.riela/` (untracked, preserve), any
`design-docs/` file (accepted design), `impl-plans/active/search-engine-fusion-dispatch.json`,
`impl-plans/active/search-engine-adapter-dispatch.json`, `mise.toml`,
`docker/meilisearch/compose.yaml`, `web/src-tauri/tauri.conf.json`,
`web/src-tauri/capabilities/default.json`, `Sources/AppServer/*`.

## Edit protocol (every plan)

1. Before each edit, read the file fresh. Record `shasum -a 256 <file>`
   as the pre-hash in `tmp/search-engine-backend-boundary/<P#>/hashes.txt`.
2. Before the first edit, write an immutable intent snapshot
   `tmp/search-engine-backend-boundary/<P#>/intent.md` (the plan's
   file-level changes in your own words). Do not rewrite it later.
3. After each edit, record the post-hash. Before the next edit of the same
   file, compare the current hash with your recorded post-hash. If it
   differs (drift), re-read the file, re-apply only your intent, and note
   the drift in your plan's Progress Log.
4. Edit only your own `writePaths`. Never edit a peer's file to make your
   build pass. A compile or lint failure caused by a peer's in-progress
   file is not a blocker: record it, rerun after the peer lands, and leave
   cross-plan fixes to P5.
5. No git write operations (no add, commit, stash, checkout, branch,
   worktree). Do not touch `.riela/`.
6. Each plan updates only the Progress Log in its own plan file.

## Evidence policy

- A behavioral record is a test-runner command (`swift test ...`,
  `bun test ...`, `vitest run ...`, or `mise run <task containing test>`)
  with exit code 0 and every count > 0. For XCTest record the
  `Executed N tests, with 0 failures` line (N > 0); for swift-testing the
  `Test run with N tests passed` line (N > 0) when the filter selects
  swift-testing tests.
- `mise run web:check` is not a behavioral record. `bun test src` and
  `vitest run` are recorded separately.
- An env-gated skip is never evidence. The live suite records only the
  XCTest count of the positive run.
- Every command is teed into the plan's evidence directory, and each
  record gives the complete log path and the final exit status.

## Completion

All five plans report Completed in their Progress Logs, P5 records the
full gate table below with positive counts, and all four client-boundary
guards return nothing.

## Final integration evidence

(P5 fills this table.)

| Gate | Result | Evidence |
| --- | --- | --- |
| `mise run build` | | |
| Full Swift tests | | |
| `mise run lint` | | |
| `bun test src` | | |
| `vitest run` | | |
| `mise run web:check` | | |
| `mise run tauri:check` | | |
| `mise run search:test-live` | | |
| Client-boundary guards (4) | | |

## Progress Log

- 2026-10-05: Plans P1-P5 created from the accepted B0-B8 design (Step 3 accept, comm-004126).
