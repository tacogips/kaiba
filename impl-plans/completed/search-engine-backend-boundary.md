# Search Engine Backend-Only Boundary (index)

**Status**: Completed. All five plans (P1-P5) were accepted in session-272. The P5 test-integrity review (comm-004170), adversarial review (comm-004171) and the combined-tree integration review (comm-004176) found no high or mid findings. The P5 gates below passed with positive counts, including the live suite. The browser E2E step was skipped because the repository has no E2E harness; the settings form is covered by the vitest component tests and the `engineBoundary.test.ts` guard. Archived to `impl-plans/completed/` at Step 8 on 2026-10-05. The dispatch manifest `impl-plans/active/search-engine-backend-boundary-dispatch.json` is a workflow runtime artifact and stays in `impl-plans/active/`. Open low follow-up: `Sources/AppCLI/GraphQLCommand.swift:155` (see Progress Log).
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
| 1 | P1-descriptor-contract | `impl-plans/completed/search-engine-backend-boundary-p1-descriptor-contract.md` | none |
| 1 | P3-web-server-default | `impl-plans/completed/search-engine-backend-boundary-p3-web-server-default.md` | none |
| 1 | P4-readme | `impl-plans/completed/search-engine-backend-boundary-p4-readme.md` | none |
| 2 | P2-backend-resolution | `impl-plans/completed/search-engine-backend-boundary-p2-backend-resolution.md` | P1 |
| 3 | P5-integration | `impl-plans/completed/search-engine-backend-boundary-p5-integration.md` | P1, P2, P3, P4 |

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

| Gate | Result | Evidence |
| --- | --- | --- |
| `mise run build` | exit 0 | `tmp/search-engine-backend-boundary/P5/build.log` |
| Full Swift tests | exit 0; XCTest 1184 run, 9 skipped, 0 failed; Swift Testing 148 passed | `tmp/search-engine-backend-boundary/P5/swift-test.log` |
| `mise run lint` | exit 0; 0 serious violations, 3 non-serious warnings in untouched baseline files | `tmp/search-engine-backend-boundary/P5/lint.log` |
| `bun test src` | exit 0; 190 pass, 0 fail | `tmp/search-engine-backend-boundary/P5/bun-test.log` |
| `vitest run` | exit 0; 100 passed, 0 failed | `tmp/search-engine-backend-boundary/P5/vitest.log` |
| `mise run web:check` | exit 0 | `tmp/search-engine-backend-boundary/P5/web-check.log` |
| `mise run tauri:check` | exit 0 | `tmp/search-engine-backend-boundary/P5/tauri-check.log` |
| `mise run search:test-live` | exit 0; XCTest 4 run, 0 failed (filtered Swift Testing run reports 0 and is not counted) | `tmp/search-engine-backend-boundary/P5/live.log` |
| Client-boundary guards (4) | exit 0; all logs empty | `guard-port.log`, `guard-client.log`, `guard-descriptor.log`, `guard-adapters.log` under `tmp/search-engine-backend-boundary/P5/` |

## Progress Log

- 2026-10-05: Plans P1-P5 created from the accepted B0-B8 design (Step 3 accept, comm-004126).
- 2026-10-05: P5 verified the combined tree. All required build, test, lint, web, Tauri and live-search gates passed; detailed exits, counts and log paths are in the Final integration evidence table and the P5 Progress Log. Docker/Meilisearch lifecycle commands `search:docker`, `search:up`, and `search:down` also exited 0 (`tmp/search-engine-backend-boundary/P5/search-docker.log`, `search-up.log`, `search-down.log`).
- 2026-10-05: The protected-path guard and refined machine-local path guard are empty. Four client-boundary guards are empty; every changed Swift file is below 1000 lines. The raw `/Users/` substring guard matched only generic grep expressions in the P4 plan, with raw output retained at `guard-local-paths-raw.log`; the refined actual-user-path guard is empty at `guard-local-paths.log`. No integration source repair was needed and no assertion was weakened.
- 2026-10-05: Empty-URL UI payload and backend GraphQL persistence are covered by the passing web component integration and GraphQL executor/backend tests. These run in their respective Bun and Swift suites rather than through a browser-to-live-server session. P4's low-scope `Sources/AppCLI/GraphQLCommand.swift` environment caveat is recorded as a follow-up in P5's Progress Log because that path is outside P5 writePaths. Formal adversarial review and workflow finalization remain pending.
- 2026-10-05: Accepted. P5 test-integrity (comm-004170), adversarial (comm-004171) and combined-tree integration review (comm-004176) passed with no high or mid findings; the browser E2E step was skipped (no E2E harness in the repository). Step 8 confirmed the README "Optional search engine" section matches the shipped behavior and archived all six plan files to `impl-plans/completed/`.
- Open follow-up (low, IR-APPCLI-SLOT-ENV): the in-process `kaiba graphql` (`Sources/AppCLI/GraphQLCommand.swift:155`) builds `NoteService` with an empty `SearchEngineSlot` environment, so a blank Settings URL saved or tested there resolves to `SearchEngineFactory.fallbackMeilisearchURL` instead of `KAIBA_MEILISEARCH_URL`. It fails closed (no `url` key is stored; a mismatched secret is never sent). Fix: call `slot.setEnvironment(ProcessInfo.processInfo.environment)` before constructing `NoteService` and add a CLI regression test. This needs a new scope because `Sources/AppCLI` was outside every plan's writePaths.
