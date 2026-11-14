# P11 Integration: docs, live test, full verification, serial repair

**Status**: Completed. Accepted in session-264 (test-integrity, adversarial and integration review, comm-003910). The combined-tree wave-8 reconcile passed (`tmp/search-engine-adapter/reconcile/session-264-wave8/reconcile-summary.md`). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P11-integration
**Wave**: 5 (session-264)
**dependsOn**: P3-elasticsearch-adapter, P7-cli, P8-server-sync-loop, P9-web-client, P12-delta-contract, P13-es-adapter-delta, P14-ontology-indexing, P15-ontology-query-service, P16-agent-search-routing, P17-settings-core, P18-graphql-client-delta, P19-runtime-controller, P20-web-delta. P1, P2, P4, P5, P6 and P10 are accepted dependencies, in commit b466ced.
**Session-264 note**: This plan integrates and documents the base feature (SE1-SE9). It runs after every implementation plan, including the delta, so its full check sees settled code. P21-delta-integration follows in wave 6 and covers D1-D5.

Three amendments:

1. The `sharedPaths` are narrowed to the concrete file list below. The ten whole directories would exceed the 512-entry snapshot limit once the delta adds about 30 files.
2. Verification records are in gate-compatible form.
3. The README purge example uses `-notes-v2`, which P13 changes, and mentions that the old `-v1` index can be deleted.
**Design Reference**: `design-docs/specs/search-engine-adapter.md` (all sections, Verification, Rollout)
**Index**: `impl-plans/completed/search-engine-adapter.md`

## Intent and context

This is the serial finalization step. It runs after every other plan has
finished:

- write the README section;
- run the gated live Elasticsearch test against the local compose cluster;
- run the full verification contract;
- repair only cross-plan integration breaks;
- update the index plan's status and evidence.

It does not commit, push or archive. Workflow finalization owns that.

## Non-goals

- No new features and no refactors.
- No reopening of design decisions.
- No changes to the default search path.
- No edits to `.riela/`.

## writePaths

- `README.md`
- `impl-plans/completed/search-engine-adapter.md`
- `impl-plans/completed/search-engine-adapter-p11-integration.md`

## sharedPaths (serial repair only, with logged hashes)

These are concrete files (session-264). The dispatch manifest lists the same set for P11 and P21. Every search-engine source, test and web file touched by P1-P20 is included:

- **AppCore engine:**
  - `SearchEngine.swift`
  - `SearchEngineSettingsTypes.swift`
  - `SearchEngineSlot.swift`
  - `SearchEngineFactory.swift`
  - `SearchEngineScope.swift`
  - `SearchEngineSyncOutbox.swift`
  - `SearchEngineSettingsResolver.swift`
  - `SearchIndexSynchronizer.swift`
  - `SearchIndexDocumentOntology.swift`
  - `ElasticsearchSearchEngine.swift`
  - `ElasticsearchRequestBodies.swift`
  - `ElasticsearchHTTPTransport.swift`
- **AppCore service:**
  - `NoteService.swift`
  - `NoteService+SearchEngine.swift`
  - `NoteService+SearchEngineOntology.swift`
  - `NoteService+SearchEngineSettings.swift`
  - `NoteService+Search.swift`
  - `NoteSearchIndex.swift`
  - `NoteService+Libraries.swift`
  - `NoteService+TagDetail.swift`
  - `NoteService+Catalog.swift`
  - `NoteTagWrites.swift`
  - `NoteService+Relations.swift`
  - `NoteService+ActionHistory.swift`
  - `NoteService+NotebookTags.swift`
  - `NoteStoreSchema.swift`
  - `KaibaConfiguration.swift`
  - `KaibaAgentToolbox.swift`
  - `CommandSearchEngine.swift`
  - `Command.swift`
- **AppCLI:** `main.swift`.
- **AppGraphQL:**
  - `GraphQLContractProjector.swift`
  - `GraphQLNoteSchemaContract.swift`
  - `NoteGraphQLDocumentExecutorSupport.swift`
  - `NoteGraphQLDocumentExecutor.swift`
  - `NoteGraphQLDocumentVariables.swift`
  - `NoteGraphQLDocumentInputs.swift`
  - `NoteGraphQLService+SearchEngine.swift`
  - `NoteGraphQLService+SearchEngineSettings.swift`
- **AppServer:**
  - `KaibaServerRuntime.swift`
  - `SearchIndexSyncLoop.swift`
  - `SearchEngineRuntimeController.swift`
- **KaibaClient:**
  - `KaibaOperations.swift`
  - `KaibaOperations+SearchEngine.swift`
  - `KaibaModels.swift`
  - `KaibaModels+SearchEngine.swift`
- **The test files of P1-P20.** See the manifest; `ElasticsearchLiveTests.swift` is included for P11.
- **web:**
  - `notes/types.ts`
  - `notes/client.ts`
  - `notes/searchEngineClient.test.ts`
  - `notes/searchEngineSettings.ts`
  - `notes/searchEngineSettings.test.ts`
  - `state/appStore.tsx`
  - `views/SearchView.tsx`
  - `views/SearchView.integration.tsx`
  - `views/ConfigView.tsx`
  - `components/RelatedNotesSection.tsx`
  - `components/RelatedNotesSection.integration.tsx`
  - `components/SearchEngineSettings.tsx`
  - `components/SearchEngineSettings.integration.tsx`
  - `panes/RightPane.tsx`

A repair outside this list is out of scope. Report it as a finding instead.

The repair rules are in `sharedPathNotes` in the dispatch manifest:

- Edit only to fix a compile or test break caused by two plans' interaction.
- Re-read the owning plan first and keep its intent.
- Log pre and post hashes in this plan's Progress Log.
- Never weaken an access-control assertion.
- Never change the pinned SDL.
- Never change the server-credential rule tests in `web/`.

## File-level changes

### `README.md`

Add a section `## Optional search engine`, after
`## External database and file storage`. It contains:

1. One paragraph on what the engine does:
   - engine search and related notes when configured;
   - built-in search unchanged when not configured;
   - access re-checked in the store.
2. The sample configuration from design SE2, verbatim. Also say that remote
   clusters use `https` and `apiKeyEnvironmentVariable`, or the
   username/password variable names, and never inline secrets.
3. Local development:
   - `mise run search:up`, `search:status` and `search:down`;
   - the compose file path;
   - an explicit note that the compose cluster runs with security disabled
     and is bound to `127.0.0.1` for local use only.
4. Operations:
   - `kaiba search-engine status|sync|reindex`;
   - the server syncs automatically: on start, on changes, and every 15
     seconds;
   - writes never fail because the engine is down;
   - to purge stale documents, delete the index
     (`curl -X DELETE http://127.0.0.1:9200/<prefix>-notes-v2`) and run
     `kaiba search-engine reindex`. After upgrading from `-v1`, the old
     `<prefix>-notes-v1` index is no longer used and can be deleted the same
     way.
5. A link to `design-docs/specs/search-engine-adapter.md`.

Use no machine-local absolute paths and no emojis.

### `impl-plans/completed/search-engine-adapter.md`

Set Status to "Implemented (pending review)", tick the completion criteria
that have evidence, and append the evidence paths to the Progress Log.

## Pitfalls

- **Classify every failure.** A failing full check must be attributed to
  its owning plan:
  - Repair here only when the cause is the interaction between plans.
  - A defect fully inside one plan's scope is reported back as a finding
    for that plan's owner.
- **Docker.** If Docker or colima is unavailable, the live test is
  `blocked`, not passed. Record the exact error.
- **Cleanup.** If this plan started the cluster with `search:up`, run
  `mise run search:down` after the live test, even when it fails. Otherwise
  leave the operator's running cluster up, because P21 needs it in wave 6.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Search 2>&1 | tee tmp/search-engine-adapter/P11/search-filter.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteStoreSchema 2>&1 | tee tmp/search-engine-adapter/P11/schema.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P11/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run web:check 2>&1 | tee tmp/search-engine-adapter/P11/web-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run tauri:check 2>&1 | tee tmp/search-engine-adapter/P11/tauri-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test 2>&1 | tee tmp/search-engine-adapter/P11/swift-test-full.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-adapter/P11/bun-test.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-adapter/P11/vitest-run.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise run check 2>&1 | tee tmp/search-engine-adapter/P11/full-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run search:status 2>&1 | tee tmp/search-engine-adapter/P11/search-status.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200 mise run search:test-live 2>&1 | tee tmp/search-engine-adapter/P11/live.log; echo exit=${PIPESTATUS[0]}'
bash -c 'find Sources Tests -name "*.swift" -exec wc -l {} + | sort -n | tail -6'
bash -c 'LC_ALL=C grep -rnP "[^\x00-\x7F]" README.md docker/elasticsearch/compose.yaml Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift || echo ascii-ok'
bash -c '! grep -rn "/Users/\|/home/" README.md docker design-docs/specs/search-engine-adapter.md impl-plans/completed/search-engine-adapter.md Sources Tests web/src'
git status --short
git diff --check
```

Expected evidence:

- `exit=0` for every Swift, lint, web, tauri and full-check run.
- **Gate-compatible behavioral records (session-264).**
  - `swift-test-full.log`: the XCTest `Executed N tests, 0 failures` N, which must be > 0.
  - `bun-test.log`: the bun pass count, > 0.
  - `vitest-run.log`: the vitest passed count, > 0.
  - `live.log`: the XCTest `Executed N tests, 0 failures` N, which must be > 0. Record only the XCTest count; the filtered run's swift-testing line reports 0 tests and is not a record.
  - Each record keeps its log path and `exit=` value.
  - `mise run check`, `web:check` and `tauri:check` are supporting records without counts.
- The env-gated skip of the live test, when `KAIBA_ELASTICSEARCH_URL` is unset, is a non-behavioral note, never evidence.
- The operator keeps the compose cluster running. Run `mise run search:up` only if `search:status` fails, and then `search:down` afterwards. If Docker is unavailable, record `blocked` with the error.
- The largest Swift file is under 1000 lines.
- `ascii-ok` is printed.
- The absolute-path guard exits 0.
- `git status` lists only planned files and logged repairs, and `.riela/`
  is unchanged.
- `git diff --check` is clean.

## Done criteria

- [x] The README section exists with the sample configuration and the
      local-only security note.
- [x] The full check passes, and the live test passes, or is explicitly
      `blocked` for lack of Docker.
- [x] Every cross-plan repair is logged with hashes. No high or mid issue
      remains unreported.
- [x] The index plan status and evidence are updated. Nothing is committed.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-05: P11 implementation completed on the shared branch. README was
  read at SHA-256 `52f07de1d90d528cbfbb157a29d5bd03289c98a2a55455a1e48e6ae92da5cf1b`
  before adding `## Optional search engine`; afterward it is
  `12c6b605551f86fd04ff77eb10ee66f9e7bd7a3bac22bc674dd036931d46f525`.
  The P11 status and done-criteria edit changed this plan from
  `f2359cc7b2fee6fe6416d2357c0cfc59e8cef27ac546d9e2059fea715765b1c8` to
  `e21284fc9f321857721f0aa2eaec1e731922f14e623abe6390acfa3a7d311e41` before
  this progress entry was appended. The final plan hash is recorded in
  `tmp/search-engine-adapter/P11/P11-plan-final.sha256`.
  - `mise run build`: exit=0, `build.log`.
  - `swift test --filter Search`: exit=0; XCTest 149 run, 0 failures,
    1 env-gated skip, plus swift-testing 12 passed; `search-filter.log`.
  - `swift test --filter NoteStoreSchema`: exit=0; XCTest 26 run, 0 failures;
    `schema.log`.
  - `mise run lint`: exit=0; 3 non-serious diagnostics, 0 serious;
    `lint.log`.
  - `mise run web:check`: exit=0; bun 187 passed and vitest 97 passed;
    `web-check.log`.
  - `mise run tauri:check`: exit=0; `tauri-check.log`.
  - Full `swift test`: exit=0; XCTest 1109 run, 0 failures, 6 skipped;
    swift-testing 146 passed; `swift-test-full.log`.
  - Separate `bun test src`: exit=0, 187 passed; `bun-test.log`.
    Separate `vitest run`: exit=0, 97 passed; `vitest-run.log`.
  - `mise run check`: exit=0; `full-check.log`.
  - `mise run search:status`: exit=0, local cluster healthy; `search-status.log`.
    `KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200 mise run search:test-live`:
    exit=0, XCTest 1 run, 0 failures; `live.log`. The operator's cluster is
    left running for P21.
  - Swift line-count guard: exit=0, largest file 997 lines;
    `swift-line-count-final.log`. Absolute-path guard: exit=0;
    `absolute-path-guard-final.log`. The P11 README section and search-engine
    sources are ASCII-only (`ascii-section-final.log`). The whole README has
    pre-existing non-ASCII punctuation at untouched lines 378 and 535;
    `ascii-final.log` records that broader check. `git diff --check`: exit=0,
    `diff-check.log`.
  - No source/test repair was needed. The worktree changes are the planned
    search-engine feature paths, the README, and these plans; `.riela/` was
    not touched. No commit or push was made.
  - P18/P19 accepted reviews defer client operation documents through
    `NoteGraphQLDocumentExecutor` and config-managed runtime-to-GraphQL
    verification to serial integration. These D5 checks remain with P21;
    the P11 base contract and gates are complete. P21 owns the README delta
  subsection and extended live scenarios.
  - The index update changed `impl-plans/completed/search-engine-adapter.md`
    from SHA-256 `c2aed667561a7be74f4732278e29534e139cca5d825edd4adb103e3fa74921a8`
    to `3e18d53e4bdf6b8702d66ed0fcb83318af4211a8bba276296b22a27953a2dc8b`.
