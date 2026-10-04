# P21 Delta integration: extended live test, README delta, full gates, serial repair

**Status**: Ready
**planId**: P21-delta-integration
**Wave**: 6
**dependsOn**: P11-integration, P12-delta-contract, P13-es-adapter-delta, P14-ontology-indexing, P15-ontology-query-service, P16-agent-search-routing, P17-settings-core, P18-graphql-client-delta, P19-runtime-controller, P20-web-delta
**Design Reference**: `design-docs/specs/search-engine-adapter.md` "Delta test plan" (Live), "Delta verification", "Delta rollout"; D0 (final delta-integration plan)
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

This is the serial finalization for the delta (D1-D5), and it runs after P11 has integrated the base. It does five things:

1. Extend the env-gated live Elasticsearch test with the three delta scenarios.
2. Add the README delta subsection.
3. Run the full gate set in the gate-compatible form, plus the boundary greps.
4. Repair only cross-plan integration breaks, with logged hashes.
5. Update the index status and evidence.

It does not commit, push or archive.

Gate rules, binding on this plan:

- A behavioral record is a command matching `swift test`, `bun test`, `vitest run` or `mise run <name containing test>`.
- It must exit 0, and every count it records (testsRun, testsPassed, testCount) must be > 0.
- It keeps the full log path and the final exit status.
- For `search:test-live`, record only the XCTest `Executed N tests, 0 failures` count. The swift-testing 0-test line is not a record.
- The env-gated skip, where the test skips when `KAIBA_ELASTICSEARCH_URL` is unset, is a non-behavioral note only.

## Non-goals

- No new features and no reopened design decisions.
- No edits to `.riela/`.
- No change to the server-credential tests.
- No commit or push.

## writePaths

- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`
- `README.md`
- `impl-plans/active/search-engine-adapter.md`
- `impl-plans/active/search-engine-adapter-p21-delta-integration.md`

## sharedPaths (serial repair only, with logged pre and post hashes)

These are the same file-level list as P11 (see the manifest). They cover every search-engine source, test and web file touched by P1-P20. Repair rules:

- Edit only to fix a break caused by two plans' interaction.
- Re-read the owning plan first and keep its intent.
- Never weaken an access-control or secret assertion.
- Never change pinned SDL lines.
- Never change the server-credential tests.

## File-level changes

### `ElasticsearchLiveTests.swift`

Keep the existing round-trip test, now on `-v2`. Add three XCTest methods, each starting with `try XCTSkipUnless(configuredURL != nil)` and each using a unique `indexPrefix` with `defer` index deletion.

1. **`testLiveOntologySearch`.** Upsert documents directly through the engine, with hand-built `pathTags`, `tagApplications` and links:
   - D1: tagged `child` (a descendant of `parent`, class `person`), with body "alpha".
   - D2: tagged `other`, with body "parent alpha".
   - D3: untagged, with body "zzz".

   Refresh, then assert:
   - `hierarchyTagIds [parent]` -> D1, but not D2.
   - Class filter `person` -> D1 only.
   - Query "parent" with `expansionTagIds [parent]` -> D1 is returned. The body lacks "parent", so it matched through the ontology. D2 is also returned via text.
   - `facets` -> a `tag_classes` bucket `person` with count 1.
2. **`testLiveRelatedReasons`.**
   - Source S has tags `[t1 (person)]`.
   - L links to S (`outgoingLinkNoteIds` contains S).
   - T shares `t1`.
   - X shares only text.
   - Query with signals, and assert that L's reasons contain `linked`, T's reasons contain `sharedTag` and `sharedEntity`, X's reasons contain `textSimilarity`, and S is excluded.
3. **`testLiveSettingsHotSwap`.** This test uses a temporary `NoteService` store with two notes.
   1. Save store settings through `updateSearchEngineSettings` (kind elasticsearch, url from the environment, prefix A, authMode none).
   2. Install a slot reload handler in the test. It calls `makeResolvedSearchEngine(configuration: nil, environment:)`, replaces the slot, then runs `ensureIndex`, `activateSearchEngineSync` and `SearchIndexSynchronizer(service:).drainUntilIdle(engine:)`.
   3. Update the settings to prefix B. The identity changes, and after the drain and a refresh, search on B finds both notes.
   4. Update to kind `none`. `service.searchEngine` is nil, and `engineSearchNotes` throws `SearchEngineError.notConfigured`.
   5. Delete both indices.

### `README.md`

Under the existing `## Optional search engine` section, which P11 writes, add `### Ontology-aware search and settings`. It covers:

- tag and class filters, ontology expansion and facets;
- related-note reasons;
- the agent tool routing;
- the precedence rule: a config section locks the settings, otherwise the web Settings section is for administrators;
- write-only secrets, bound to the URL and auth mode;
- Test connection;
- hot-swap with no restart;
- the `-v2` backfill on upgrade, and how to delete the old `-v1` index.

Use no absolute paths, no secrets and no emojis.

### `impl-plans/active/search-engine-adapter.md`

Set Status to `Implemented (pending review)` for the delta rows. Tick the completion criteria that have evidence, and append the evidence paths.

## Pitfalls

- **Docker.** If it is unavailable, record `blocked: docker unavailable` with the exact error. Never record it as passed. Run `mise run search:down` only if this plan started the cluster. The operator keeps it running, so check `mise run search:status` first and log the result.
- **Failure attribution.** Classify each failure: an in-scope defect of one plan is reported as a finding for that plan, not repaired here.
- **Live test isolation.** Use unique prefixes, and delete the indices even on failure.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test 2>&1 | tee tmp/search-engine-adapter/P21/swift-test-full.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P21/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-adapter/P21/bun-test.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-adapter/P21/vitest-run.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && mise run web:check 2>&1 | tee tmp/search-engine-adapter/P21/web-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && mise run tauri:check 2>&1 | tee tmp/search-engine-adapter/P21/tauri-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && mise run search:status 2>&1 | tee tmp/search-engine-adapter/P21/search-status.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P21 && KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200 mise run search:test-live 2>&1 | tee tmp/search-engine-adapter/P21/live.log; echo exit=${PIPESTATUS[0]}'
bash -c '! grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+SearchEngine*.swift Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift'
bash -c 'find Sources Tests -name "*.swift" -exec wc -l {} + | sort -n | tail -6'
bash -c '! grep -rn "/Users/\|/home/" README.md docker design-docs/specs/search-engine-adapter.md impl-plans/active/search-engine-adapter.md Sources Tests web/src'
git diff --stat -- web/src/notes/client.test.ts web/src/notes/serverEndpoint.test.ts .riela
git status --short
git diff --check
```

Expected evidence:

- `swift-test-full.log`: `exit=0`. Record the XCTest `Executed N tests, 0 failures` N, which must be greater than 0, and the swift-testing passed count separately.
- `bun-test.log` and `vitest-run.log`: `exit=0` with positive counts, recorded separately.
- `lint`, `web:check` and `tauri:check`: `exit=0`.
- `live.log`: `exit=0` and `Executed 4 tests, 0 failures`, recording only the XCTest count. Otherwise record `blocked` with the error.
- The boundary grep and the absolute-path guard exit 0. The guard scans only `impl-plans/active/search-engine-adapter.md` among plan files, because the plan and manifest files contain the guard text itself. Never edit other workflows' files to make it pass. The largest Swift file is under 1000 lines.
- The `git diff --stat` for the credential tests and `.riela` is empty. `git status` lists only planned files and logged repairs.

## Done criteria

- [ ] The live test covers ontology search, related reasons and settings hot-swap, and passes against the compose cluster, or is reported blocked.
- [ ] The README delta subsection exists.
- [ ] Every gate record is in gate-compatible form with positive counts and log paths.
- [ ] Cross-plan repairs are logged with hashes, and no high or mid issue remains unreported. The index is updated. Nothing is committed.

## Progress Log

- 2026-10-04: Plan created (session-264).
