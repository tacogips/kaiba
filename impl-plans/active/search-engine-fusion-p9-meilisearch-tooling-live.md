# P9 Meilisearch local tooling, live suite and runtime hot-swap test

**Status**: Not Started
**planId**: P9-meilisearch-tooling-live
**Wave**: 3
**dependsOn**: P2-engine-seeded-retrieval, P3-meilisearch-adapter
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F5, F4 (hot-swap reuse), F3 (live acceptance gate)
**Index**: `impl-plans/active/search-engine-fusion.md`

## Intent and context

This plan adds:

- a loopback-only Meilisearch compose service with a pinned image tag;
- mise tasks consistent with `search:*`, reusing `search:docker` (colima
  on macOS);
- an env-gated live suite proving the adapter against a real Meilisearch,
  including Japanese search and engine-seeded graph retrieval;
- an AppServer test proving that a settings reload hot-swaps to a
  Meilisearch adapter.

Repository facts and patterns:

- `docker/elasticsearch/compose.yaml`: service, `container_name`,
  loopback port, named volume, healthcheck, and the local-only comment.
- `mise.toml` lines ~233-275:
  - `search:docker`, `search:up` (`depends = ["search:docker"]`,
    `docker compose ... up -d --wait`), `search:down`, `search:status`;
  - `search:test-live` (`depends = ["anydoc:native", "search:up"]`,
    `KAIBA_ELASTICSEARCH_URL=${...:-http://127.0.0.1:9200} swift test --filter ElasticsearchLive`,
    and the `[tasks."search:test-live".env]` table setting
    `PKG_CONFIG_PATH = "{{config_root}}/.build/anydoc-native/host/pkgconfig"`).
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`: the live template
  (`XCTSkipUnless`, unique prefix, cleanup in `defer`, service-level
  settings hot-swap test with `ReloadFailures`).
- `Tests/AppServerTests/SearchEngineRuntimeControllerTests.swift`:
  `ControllerFakeSearchEngine` and the controller construction pattern.
  Production `makeEngine` is
  `service.makeResolvedSearchEngine(configuration:environment:)`
  (`Sources/AppServer/KaibaServerRuntime.swift:144`).
- `NoteService.updateSearchEngineSettings(_:)` and
  `SearchEngineSettingsInput` (`Sources/AppCore/SearchEngineSettingsTypes.swift`).

## Non-goals

- No adapter code changes. Adapter defects go into the progress log for
  P10.
- No change to Elasticsearch tasks or compose.
- No README text (P7).

## writePaths

- `docker/meilisearch/compose.yaml`
- `mise.toml`
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`
- `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift`
- `impl-plans/active/search-engine-fusion-p9-meilisearch-tooling-live.md`
- `tmp/search-engine-fusion/P9`

## sharedPaths (read-only)

- `docker/elasticsearch/compose.yaml`
- `Sources/AppCore/MeilisearchSearchEngine.swift`
- `Sources/AppCore/SearchEngineFactory.swift`
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`
- `Sources/AppServer/SearchEngineRuntimeController.swift`
- `Sources/AppServer/KaibaServerRuntime.swift`
- `Tests/AppCoreTests/ElasticsearchLiveTests.swift`

## sharedPathNotes

- `mise.toml`: intendedEdit: append the four `search:meilisearch:*` tasks
  after the existing `search:test-live` env table. Do not modify any
  existing task.
- `docker/meilisearch/compose.yaml`: intendedEdit: new authored compose file (not an artifact).
- `Tests/AppCoreTests/MeilisearchLiveTests.swift`: intendedEdit: new env-gated live suite.
- `Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift`: intendedEdit: new runtime hot-swap test.
- `Sources/AppCore/MeilisearchSearchEngine.swift`: intendedEdit: read-only; written by P3.
- `Sources/AppCore/SearchEngineFactory.swift`: intendedEdit: read-only; written by P3.
- `Sources/AppCore/NoteService+EngineSeededRetrieval.swift`: intendedEdit: read-only; written by P2.
- `tmp/search-engine-fusion/P9`: intendedEdit: generated evidence logs only (pull, digest, up, live and runtime logs).

## artifactRoots

- `tmp/search-engine-fusion/P9`

No tool or image is installed into the repository. The Docker image lives
in the Docker daemon. Its provenance (the pinned tag, the RepoDigest, the
pull command and its exit code) is recorded in this plan's tracked
Progress Log, as required below.

## File-level changes

1. `docker/meilisearch/compose.yaml`:
   - service `meilisearch`, `container_name: kaiba-meilisearch`;
   - image `getmeili/meilisearch:v1.<minor>.<patch>`. Pick a v1.10 or
     later tag and verify it with `docker pull`. Record its digest with
     `docker image inspect --format '{{index .RepoDigests 0}}' getmeili/meilisearch:<pinned-tag>`.
     The Progress Log of this plan must state the pinned tag, the
     RepoDigest, the exact pull command and its exit code;
   - environment `MEILI_ENV: development` and `MEILI_NO_ANALYTICS: "true"`,
     with no master key;
   - port `"127.0.0.1:7700:7700"`, volume
     `kaiba-meilisearch-data:/meili_data`;
   - a healthcheck on `http://localhost:7700/health` using a tool that
     exists in the image (check with
     `docker run --rm --entrypoint sh <image> -c 'command -v curl wget'`;
     use whichever exists);
   - a top comment: local development only, no master key, loopback only.
2. `mise.toml`:
   - `search:meilisearch:up` (`depends = ["search:docker"]`) runs
     `docker compose -f docker/meilisearch/compose.yaml up -d --wait`;
   - `search:meilisearch:down` runs `down`;
   - `search:meilisearch:status` runs
     `curl -fsS http://127.0.0.1:7700/health`;
   - `search:meilisearch:test-live`
     (`depends = ["anydoc:native", "search:meilisearch:up"]`) runs
     `KAIBA_MEILISEARCH_URL=${KAIBA_MEILISEARCH_URL:-http://127.0.0.1:7700} swift test --filter MeilisearchLive`,
     with an env table setting the same `PKG_CONFIG_PATH`.
3. `MeilisearchLiveTests` (XCTest, `XCTSkipUnless(KAIBA_MEILISEARCH_URL != nil)`
   on every test). Each test uses the prefix
   `kaiba-test-<8 hex>` and deletes `/indexes/<prefix>-notes-v1` in a
   `defer` with a direct `DELETE` request:
   - Round trip: `ensureIndex` twice. Upsert English "weather forecast
     sunny skies", Japanese `東京の天気` (write it with Unicode escapes, as
     the Elasticsearch live test does), and related "weather forecast rain
     tomorrow". "weather" finds english. `東京` finds japanese. `relatedNotes`
     of english contains related and not english. Delete english, then
     search no longer returns it. Writes are synchronous after the task
     wait, so there is no refresh step.
   - Ontology: documents with path tags and classes. A hierarchy filter on
     the parent finds the descendant-tagged note. A class filter
     restricts. With `expansionTagIds`, a tag-only note ranks above a
     text-only note. Facets are non-nil and contain the class.
   - Related signals: a linked note, then a shared-tag note, then a
     text-only note, with reasons `.linked`, `.sharedTag` and
     `.textSimilarity`. The source is never returned.
   - Service level: a store with an admin service.
     `updateSearchEngineSettings` with kind `meilisearch`, the URL and a
     unique prefix (no reload handler is needed; attach the built engine
     through `searchEngine`), `activateSearchEngineSync`, then drain with
     `SearchIndexSynchronizer` until nothing is due. Engine-only note A is
     linked to B. Then `retrieveNotes(query: <A-only term>, includeLinked: true)`
     returns `usedSearchEngine == true`, A with `search-engine`
     provenance, and B as a neighbor. Imitate the service-level part of
     `ElasticsearchLiveTests`.
4. `SearchEngineRuntimeMeilisearchTests` (AppServer, XCTest, no network):
   - start a controller whose `makeEngine` returns a
     `ControllerFakeSearchEngine` style fake, with a no-op loop (define a
     local fake; do not edit the existing test file);
   - store settings of kind `meilisearch` (`http://127.0.0.1:7700`,
     `authMode none`);
   - reload with `makeEngine` set to the production resolver;
   - after reload, the slot's engine `indexIdentity` starts with
     `meilisearch:http://127.0.0.1:7700/`, a `scoped(to:)` service copy
     sees the same identity, and the result is active.

     Use a `makeLoop` whose loop does not touch the network, or assert
     before the loop runs `ensureIndex`. Follow the existing tests for
     loop injection.

## Invariants

- The compose port is bound to 127.0.0.1 only. The image tag is pinned
  (no `latest`).
- Existing `search:*` tasks are unchanged.
- The live tests skip cleanly without the env variable. That skip is never
  recorded as evidence.

## Pitfalls

- macOS Docker runs through colima. Always run the `:up` task, which
  depends on `search:docker`, rather than raw `docker compose`.
- Delete every index created, even on assertion failure (`defer`).
- If the Japanese assertion fails on the stock image, do not change
  engines or tokenizer settings ad hoc. Record the failure, the image tag
  and the response in the progress log, and mark it a blocker for P10 and
  user-qa (design F3).
- Record the XCTest `Executed N tests` line, not the swift-testing
  summary.

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P9
bash -c 'docker pull getmeili/meilisearch:<pinned-tag> 2>&1 | tee tmp/search-engine-fusion/P9/pull.log; echo exit=${PIPESTATUS[0]}'
bash -c "docker image inspect --format '{{index .RepoDigests 0}}' getmeili/meilisearch:<pinned-tag> 2>&1 | tee tmp/search-engine-fusion/P9/image-digest.log; echo exit=\${PIPESTATUS[0]}"
bash -c 'mise run search:meilisearch:up 2>&1 | tee tmp/search-engine-fusion/P9/up.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run search:meilisearch:status 2>&1 | tee tmp/search-engine-fusion/P9/status.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mise run search:meilisearch:test-live 2>&1 | tee tmp/search-engine-fusion/P9/live.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "SearchEngineRuntimeMeilisearchTests|SearchEngineRuntimeControllerTests" 2>&1 | tee tmp/search-engine-fusion/P9/runtime.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
bash -c 'mise run lint 2>&1 | tee tmp/search-engine-fusion/P9/lint.log; echo exit=${PIPESTATUS[0]}'
swiftlint lint --strict --quiet --no-cache Tests/AppCoreTests/MeilisearchLiveTests.swift Tests/AppServerTests/SearchEngineRuntimeMeilisearchTests.swift
grep -n "127.0.0.1:7700:7700" docker/meilisearch/compose.yaml
grep -n "image:" docker/meilisearch/compose.yaml
```

Expected evidence:

- pull `exit=0`, and the digest log shows a `getmeili/meilisearch@sha256:...`
  RepoDigest with `exit=0`. The Progress Log records the tag, digest,
  pull command and exit code.
- up `exit=0`.
- status shows `{"status":"available"}`.
- The live run shows `exit=0` and the XCTest line
  `Executed N tests, 0 failures` with N >= 4. Record only that line.
- The runtime run shows `exit=0` with N > 0.
- Strict swiftlint is clean.
- The compose port line is present, and the image line has a pinned
  `v1.x.y` tag.

## Done criteria

- [ ] Compose and tasks exist and work through `search:docker`.
- [ ] The live suite passes with a positive XCTest count against the
      pinned image, including the Japanese query.
- [ ] The runtime hot-swap test passes.
- [ ] Evidence is recorded in the Progress Log: the pinned tag, the
      RepoDigest, the pull command with its exit code, the log paths and
      the counts.

## Progress Log

- 2026-10-05: Plan created.
