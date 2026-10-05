# P10 Integration: reconcile, full gate set, both live suites

**Status**: Not Started
**planId**: P10-integration
**Wave**: 4
**dependsOn**: P1-fusion-contract, P2-engine-seeded-retrieval, P3-meilisearch-adapter, P4-agent-search-notes, P5-agentic-grounding, P6-graphql-client-provenance, P7-docs, P8-web-settings-test, P9-meilisearch-tooling-live
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` (Verification, Rollout, Invariants)
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

Join all plans on the shared working tree. Fix cross-plan compile and lint
issues serially. Run the complete verification set, including both live
engine suites. Check the design invariants mechanically and update the
plan index. This plan may edit the P1-P9 source files listed under
writePaths, and only to repair integration defects. Each repair is
recorded with the owning plan, the file, the pre and post hashes and the
reason.

## Non-goals

- No new features and no refactoring beyond what a failing check
  requires.
- No commits, branch operations or archiving. Archiving and commits happen
  at workflow finalization.
- Do not touch `.riela/`.

## writePaths

- `impl-plans/active/search-engine-fusion.md`
- `impl-plans/active/search-engine-fusion-p10-integration.md`
- `Sources/AppCore/NoteRetrievalReranker.swift`
- `Sources/AppCore/NoteModels.swift`
- `Sources/AppCore/NoteSearch.swift`
- `Sources/AppCore/SearchEngineHTTPTransport.swift`
- `Sources/AppCore/ElasticsearchHTTPTransport.swift`
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Sources/AppCore/MeilisearchSearchEngine.swift`
- `Sources/AppCore/MeilisearchRequestBodies.swift`
- `Sources/AppCore/MeilisearchResponses.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/KaibaAgentToolbox.swift`
- `Sources/AppCore/AIAgenticSearch.swift`
- `Sources/AppGraphQL/NoteGraphQLService.swift`
- `Sources/AppGraphQL/NoteGraphQLService+EngineSeededSearch.swift`
- `Sources/AppGraphQL/NoteGraphQLContracts.swift`
- `Sources/AppGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/AppGraphQL/NoteGraphQLDocumentExecutorSupport.swift`
- `Sources/KaibaClient/KaibaModels.swift`
- `Sources/KaibaClient/KaibaOperations.swift`
- `Tests/AppCoreTests/NoteRetrievalRerankerTests.swift`
- `Tests/AppCoreTests/EngineSeededRetrievalTests.swift`
- `Tests/AppCoreTests/MeilisearchSearchEngineTests.swift`
- `Tests/AppCoreTests/MeilisearchFactoryTests.swift`
- `Tests/AppCoreTests/SearchEngineFactoryTests.swift`
- `Tests/AppCoreTests/AgentSearchNotesFusionTests.swift`
- `Tests/AppCoreTests/AgentSearchNotesRoutingTests.swift`
- `Tests/AppCoreTests/AgenticGroundingEngineTests.swift`
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`
- `Tests/AppGraphQLTests/EngineSeededSearchGraphQLTests.swift`
- `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift`
- `Tests/KaibaClientTests/KaibaTypedOperationContractTests.swift`
- `web/src/components/SearchEngineSettings.integration.tsx`
- `web/dist`
- `web/src-tauri/target`
- `README.md`
- `mise.toml`
- `docker/meilisearch/compose.yaml`
- `tmp/search-engine-fusion/P10`

Ownership rule: the source paths above are the union of the P1-P9 source
files. They are edited only to fix integration defects. If a repair is
needed in a file not listed here, stop. Record the file and the failure,
and report it as an unresolved finding for the review step. Do not edit
unlisted files.

## sharedPaths (read-only)

- `design-docs/specs/design-search-engine-fusion.md`
- `design-docs/user-qa/search-engine-adapter.md`
- `Tests/AppCoreTests/NoteRetrievalFusionTests.swift`
- `Tests/AppCoreTests/KaibaAgentToolboxTests.swift`
- `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift`
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`

## sharedPathNotes

- `README.md`: intendedEdit: fact corrections only (for example, task names checked against `mise.toml` after P9).
- `Sources/AppCore/MeilisearchRequestBodies.swift`: intendedEdit: repair only. Narrow `attributesToRetrieve` only if P9 recorded live evidence that `_formatted` includes cropped attributes without retrieval.
- `Sources/AppGraphQL/NoteGraphQLService+EngineSeededSearch.swift`: intendedEdit: exists only if P6 created it; repair only.
- `Tests/AppCoreTests/NoteRetrievalFusionTests.swift`: intendedEdit: read-only and protected; must stay unmodified.
- `Tests/AppCoreTests/KaibaAgentToolboxTests.swift`: intendedEdit: read-only and protected; must stay unmodified.
- `Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift`: intendedEdit: read-only and protected; must stay unmodified.
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`: intendedEdit: read-only and protected; must stay unmodified.
- `web/dist`: intendedEdit: generated `vite build` output from `mise run web:check` only.
- `web/src-tauri/target`: intendedEdit: generated cargo build output from `mise run tauri:check` only (gitignored); never edited by hand.
- `tmp/search-engine-fusion/P10`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P10`
- `web/dist`
- `web/src-tauri/target`

## Steps

1. Read every plan's progress log. List the open drift notes, peer
   failures and blockers. If P9 recorded a Japanese-segmentation blocker,
   stop: report it as unresolved and add it to
   `design-docs/user-qa/search-engine-adapter.md` only through the
   workflow's design step, not here.
2. `mise run build`. Fix compile errors serially and record each fix.
3. Full Swift test run. Fix failures caused by cross-plan interaction.
   Never weaken an existing assertion. The only sanctioned existing-test
   edits are the three listed in the plans: the P3 adapters expectation,
   the P4 removal of one routing test, and the P6 client selection
   expectation.
4. Lint, then the web checks, `tauri:check` and both live suites.
5. Mechanical invariant checks (commands below): the boundary grep, line
   counts, no Elasticsearch adapter diff, protected tests unmodified, and
   no machine-local paths.
6. If P9 recorded that `_formatted` includes cropped attributes without
   retrieval, narrow `attributesToRetrieve` in
   `MeilisearchRequestBodies.swift` and rerun the Meilisearch mock and
   live suites.
7. Check the README facts written by P7 (wave 3, after P3) against the
   final code: the task names in `mise.toml` (P9), the compose port, the
   adapter kinds and the auth modes. Correct only factual mismatches.
8. Update the index status and the summary table with the final evidence
   paths.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P10
bash -c 'mise run build 2>&1 | tee tmp/search-engine-fusion/P10/build.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test 2>&1 | tee tmp/search-engine-fusion/P10/swift-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P10/lint.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bun test src 2>&1 | tee ../tmp/search-engine-fusion/P10/bun-test.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'cd web && mise exec -- bunx vitest run 2>&1 | tee ../tmp/search-engine-fusion/P10/vitest.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run web:check 2>&1 | tee tmp/search-engine-fusion/P10/web-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run tauri:check 2>&1 | tee tmp/search-engine-fusion/P10/tauri-check.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:test-live 2>&1 | tee tmp/search-engine-fusion/P10/es-live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:meilisearch:test-live 2>&1 | tee tmp/search-engine-fusion/P10/meili-live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+SearchEngine*.swift Sources/AppCore/NoteService+EngineSeededRetrieval.swift Sources/AppCore/NoteRetrievalReranker.swift Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift Sources/AppCore/Meilisearch*.swift; echo boundary-exit=$?
git diff --stat -- Sources/AppCore/ElasticsearchSearchEngine.swift Sources/AppCore/ElasticsearchRequestBodies.swift Sources/AppCore/SearchEngine.swift
git diff --stat -- Tests/AppCoreTests/NoteRetrievalFusionTests.swift Tests/AppCoreTests/KaibaAgentToolboxTests.swift Tests/AppCoreTests/ElasticsearchSearchEngineTests.swift Tests/AppCoreTests/ElasticsearchLiveTests.swift
{ git diff --name-only; git ls-files --others --exclude-standard; } | grep -E "\.swift$" | xargs wc -l | sort -n | tail -20
git status --porcelain
grep -rnE "/Users/|/home/" README.md docker/meilisearch impl-plans/active/search-engine-fusion*.md design-docs/specs/design-search-engine-fusion.md; echo path-exit=$?
```

Expected evidence:

- build, swift test, lint, bun, vitest, web:check, tauri:check and both
  live runs each show `exit=0`.
- Counts:
  - full swift test: XCTest `Executed N tests, 0 failures` with N > 0,
    and the swift-testing pass count > 0;
  - bun: `N pass`, N > 0;
  - vitest: `Tests N passed`, N > 0;
  - each live run: its XCTest `Executed N tests, 0 failures`, N > 0.
- The boundary grep prints nothing (`boundary-exit=1`).
- The Elasticsearch and protocol diff stat is empty.
- The protected-tests diff stat is empty.
- Every changed Swift file is under 1000 lines.
- `git status` shows only the intended files plus the untouched
  `?? .riela/`.
- `path-exit=1`.

## Done criteria

- [ ] All gates pass with positive counts, recorded with log paths and
      exit codes.
- [ ] Invariant checks pass.
- [ ] Every integration repair is recorded with its owner, file, hashes
      and reason.
- [ ] The index status is updated. Any unresolved blocker is reported
      explicitly.

## Progress Log

- 2026-10-05: Plan created.
