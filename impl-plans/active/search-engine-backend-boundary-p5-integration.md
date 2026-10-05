# P5 Integration: reconcile, full gate set, live suite, boundary guards

**Status**: Not started
**planId**: P5-integration
**Wave**: 3
**dependsOn**: P1-descriptor-contract, P2-backend-resolution, P3-web-server-default, P4-readme
**Design Reference**: `design-docs/specs/search-engine-adapter.md` "B verification", "B rollout", B0 (premise), B6 (guard)
**Index**: `impl-plans/active/search-engine-backend-boundary.md`

## Intent and context

Join P1-P4 on the shared working tree, fix cross-plan compile, lint and
test defects serially, run the complete B verification set (including the
live Meilisearch suite), check the client-boundary guards and the
repository invariants mechanically, and fill the index's gate table.
This plan may edit the P1-P4 files listed under writePaths, and only to
repair integration defects. Each repair is recorded in the Progress Log
with the owning plan, the file, the pre and post hashes and the reason.

## Non-goals

- No new features, no refactoring, no new tests beyond what a failing
  check requires. Never weaken an existing assertion.
- No commits, branch operations or plan archiving (those happen at
  workflow finalization).
- Do not touch `.riela/`, any `design-docs/` file, `mise.toml`,
  `docker/meilisearch/compose.yaml`, `web/src-tauri/tauri.conf.json`,
  `web/src-tauri/capabilities/default.json` or `Sources/AppServer/*`.
  If a repair seems to need one of them, stop and report it as an
  unresolved finding.

## writePaths

- `impl-plans/active/search-engine-backend-boundary.md`
- `impl-plans/active/search-engine-backend-boundary-p5-integration.md`
- `Sources/AppCore/SearchEngineSettingsTypes.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/NoteService+SearchEngineSettings.swift`
- `Sources/AppCore/SearchEngineSettingsResolver.swift`
- `Sources/AppCore/KaibaConfiguration.swift`
- `Sources/AppCore/CommandSearchEngine.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/AppGraphQL/NoteGraphQLService+SearchEngineSettings.swift`
- `Sources/KaibaClient/KaibaModels+SearchEngine.swift`
- `Sources/KaibaClient/KaibaOperations+SearchEngine.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `Tests/AppCoreTests/KaibaSearchEngineConfigurationDecodingTests.swift`
- `Tests/AppCoreTests/SearchEngineSettingsTests.swift`
- `Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift`
- `Tests/AppGraphQLTests/SearchEngineSettingsGraphQLTests.swift`
- `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift`
- `Tests/KaibaClientTests/KaibaSearchEngineOperationTests.swift`
- `web/src/notes/types.ts`
- `web/src/notes/client.ts`
- `web/src/notes/searchEngineSettings.ts`
- `web/src/notes/searchEngineSettings.test.ts`
- `web/src/notes/engineBoundary.test.ts`
- `web/src/components/SearchEngineSettings.tsx`
- `web/src/components/SearchEngineSettings.integration.tsx`
- `README.md`
- `web/dist`
- `web/src-tauri/target`
- `tmp/search-engine-backend-boundary/P5`

Ownership rule: the source paths above are exactly the union of the P1-P4
source files. Edit them only to fix integration defects. If a repair is
needed in any other file, stop, record the file and the failure, and
report it as an unresolved finding.

## sharedPaths (read-only)

- `design-docs/specs/search-engine-adapter.md`
- `design-docs/user-qa/search-engine-adapter.md`
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`

## sharedPathNotes

- `README.md`: intendedEdit: fact corrections only, checked against the final code.
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`: intendedEdit: read-only; the live suite must pass unmodified.
- `web/dist`: intendedEdit: generated `vite build` output from `mise run web:check` only.
- `web/src-tauri/target`: intendedEdit: generated cargo output from `mise run tauri:check` only.
- `tmp/search-engine-backend-boundary/P5`: intendedEdit: evidence logs only.

## artifactRoots

- `tmp/search-engine-backend-boundary/P5`
- `web/dist`
- `web/src-tauri/target`

## Steps

1. Read every plan's Progress Log. List open drift notes, peer failures
   and blockers.
2. `mise run build`. Fix compile errors serially; record each fix.
3. Full Swift test run. Fix failures caused by cross-plan interaction.
   The only sanctioned edits to pre-existing assertions are the ones the
   plans list (P1: the two `adapters(environment:)` lines; P2: adding
   `environment: [:]` to existing resolver calls).
4. Lint, the web checks (`bun test src`, `vitest run`, `web:check`),
   `tauri:check` and the live suite (`search:docker`, `search:up`,
   `search:test-live`, then `search:down`).
5. Run the client-boundary guards and the invariant checks below.
6. Check the P4 README facts against the final code (env var name,
   fallback URL, empty-counts-as-omitted, secret re-entry). Correct only
   factual mismatches.
7. Fill the index's "Final integration evidence" table and set the index
   status line.

## Verification

```bash
mkdir -p tmp/search-engine-backend-boundary/P5
bash -c 'mise run build 2>&1 | tee tmp/search-engine-backend-boundary/P5/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test 2>&1 | tee tmp/search-engine-backend-boundary/P5/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-backend-boundary/P5/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-backend-boundary/P5/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-backend-boundary/P5/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/search-engine-backend-boundary/P5/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run tauri:check 2>&1 | tee tmp/search-engine-backend-boundary/P5/tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:docker 2>&1 | tee tmp/search-engine-backend-boundary/P5/search-docker.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:up 2>&1 | tee tmp/search-engine-backend-boundary/P5/search-up.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:test-live 2>&1 | tee tmp/search-engine-backend-boundary/P5/live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:down 2>&1 | tee tmp/search-engine-backend-boundary/P5/search-down.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'grep -rn "7700" web/src | tee tmp/search-engine-backend-boundary/P5/guard-port.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-port.log'
bash -c 'grep -rn "defaultURL" web/src Sources/AppGraphQL Sources/KaibaClient | tee tmp/search-engine-backend-boundary/P5/guard-client.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-client.log'
bash -c 'grep -n "defaultURL" Sources/AppCore/SearchEngineSettingsTypes.swift | tee tmp/search-engine-backend-boundary/P5/guard-descriptor.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-descriptor.log'
bash -c 'grep -rn "adapters(environment" Sources Tests | tee tmp/search-engine-backend-boundary/P5/guard-adapters.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-adapters.log'
bash -c 'git status --porcelain | tee tmp/search-engine-backend-boundary/P5/changed-files.log'
bash -c 'git diff | grep -n "/Users/" | tee tmp/search-engine-backend-boundary/P5/guard-local-paths.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-local-paths.log'
bash -c 'git diff --name-only -- design-docs mise.toml docker web/src-tauri Sources/AppServer | tee tmp/search-engine-backend-boundary/P5/guard-protected.log; test ! -s tmp/search-engine-backend-boundary/P5/guard-protected.log'
bash -c '{ git diff --name-only -- "*.swift"; git ls-files --others --exclude-standard -- "*.swift"; } | xargs wc -l | tee tmp/search-engine-backend-boundary/P5/wc.log'
```

Expected evidence:

- build exit 0.
- Full Swift test exit 0: record the XCTest `Executed N tests, with K
  tests skipped and 0 failures` line (N > 0) and the swift-testing
  `Test run with M tests passed` line (M > 0).
- lint exit 0 with 0 serious violations (pre-existing warnings in
  untouched files are listed, not fixed).
- bun: exit 0, `N pass`, `0 fail`, N > 0. vitest: exit 0, `Tests M
  passed`, M > 0. Recorded as two separate records.
- web:check and tauri:check exit 0 (not behavioral records).
- Live: exit 0. Record only the XCTest `Executed N tests, with 0
  failures` line with N > 0; the swift-testing line of this filtered run
  prints 0 tests and is not a count record. If Docker or colima is
  unavailable, record `blocked: <exact error>`, never passed.
- All four client-boundary guards, the local-path guard and the
  protected-path guard exit 0 with empty logs. Note: the design-doc
  changes were committed with the design before fanout, so
  `git diff -- design-docs` is empty during implementation; if it is not,
  report it instead of reverting anything.
- Every changed Swift file is under 1000 lines.
- `changed-files.log` lists only P1-P4 paths (including the new untracked
  `Tests/AppGraphQLTests/SearchEngineBackendBoundaryGraphQLTests.swift`
  and `web/src/notes/engineBoundary.test.ts`), the plan files, and the
  pre-existing `?? .riela/` entry, which must be left untouched.

## Done criteria

- [ ] Every gate in the index table filled with exit status, counts and log path.
- [ ] Four client-boundary guards empty; protected paths unchanged; no machine-local paths.
- [ ] Every integration repair recorded (owning plan, file, pre/post hash, reason).
- [ ] No unresolved high or mid finding; any blocker reported explicitly.

## Progress Log

- 2026-10-05: Plan created.
