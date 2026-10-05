# P7 README: choosing an engine, Meilisearch setup, engine-seeded search

**Status**: Completed. Accepted in session-268 (test-integrity, adversarial and combined-tree integration review, comm-004081). The P10 combined-tree gates passed (`impl-plans/completed/search-engine-fusion.md`, "Final integration evidence"). Archived to `impl-plans/completed/` at Step 8 on 2026-10-05.
**planId**: P7-docs
**Wave**: 3
**dependsOn**: P3-meilisearch-adapter (the documented config, identity and auth modes exist and are tested before the README describes them; P10 checks the task names against `mise.toml` after P9 lands)
**Design Reference**: `design-docs/specs/design-search-engine-fusion.md` F6, F3 "Engine choice", F4 README guidance, F5 task names
**Index**: `impl-plans/completed/search-engine-fusion.md`

## Intent and context

The README must explain how to choose between Elasticsearch and
Meilisearch and what each needs in resources. It must give the Meilisearch
config and local tasks, recommend a restricted API key, and describe
engine-seeded graph and agent search with the FTS fallback.
`design-docs/specs/command.md` was already updated in the design step.

Repository facts:

- `README.md` (575 lines):
  - line 13 mentions the optional Elasticsearch engine;
  - the "Optional search engine" section is around lines 185-270 (config
    sample, local compose, `kaiba search-engine` commands, settings).
- Task names fixed by the design: `search:meilisearch:up`,
  `search:meilisearch:down`, `search:meilisearch:status` and
  `search:meilisearch:test-live`.
- The compose file is `docker/meilisearch/compose.yaml`, and the port is
  `127.0.0.1:7700`.
- P3 provides the Meilisearch factory registration (`kind: "meilisearch"`,
  auth modes `none`/`apiKey`, identity
  `meilisearch:<target>/<prefix>-notes-v1`), covered by
  `MeilisearchFactoryTests`.
- README.md has no other writer in wave 3 (P4, P5, P6 and P9 do not touch
  it).

## Non-goals

- No edits to design docs, code, `mise.toml` or compose files.
- No hard-coded memory measurements. State the configured Elasticsearch
  heap (512 MB) and describe Meilisearch qualitatively (single Rust
  binary, no JVM).
- No machine-local absolute paths and no secrets.

## writePaths

- `README.md`
- `impl-plans/completed/search-engine-fusion-p7-docs.md`
- `tmp/search-engine-fusion/P7`

## sharedPaths (read-only)

- `design-docs/specs/design-search-engine-fusion.md`
- `design-docs/specs/search-engine-adapter.md`
- `Sources/AppCore/SearchEngineFactory.swift`

## sharedPathNotes

- `README.md`: intendedEdit: extend the existing "Optional search engine" section and the line-13 mention (items 1-7 below).
- `Sources/AppCore/SearchEngineFactory.swift`: intendedEdit: read-only; the source of the documented adapter kinds and auth modes (written by P3).
- `tmp/search-engine-fusion/P7`: intendedEdit: generated evidence logs only.

## artifactRoots

- `tmp/search-engine-fusion/P7`

## Content to add (in the existing "Optional search engine" section)

1. **Choosing an engine**: a short table comparing Elasticsearch and
   Meilisearch on runtime and resources, Japanese analysis (`cjk` bigrams
   versus built-in Japanese segmentation with the `jpn` locale), related
   notes (`more_like_this` versus composed in kaiba) and auth modes
   (`none`/`basic`/`apiKey` versus `none`/`apiKey`).
2. **Meilisearch config sample**:
   `{"searchEngine": {"kind": "meilisearch", "url": "http://127.0.0.1:7700", "indexPrefix": "kaiba"}}`.
   A remote setup adds
   `"apiKeyEnvironmentVariable": "KAIBA_MEILISEARCH_API_KEY"` with `https`.
3. **Local Meilisearch**: `mise run search:meilisearch:up` (it starts
   colima on macOS through `search:docker`), plus `:status`, `:down` and
   `:test-live`. Development mode has no master key and binds to
   loopback, for local use only.
4. **API key advice**: use a key restricted to the `<prefix>-notes-*`
   indexes and to the actions search, documents add/delete, indexes
   create/get, settings update and tasks get. Never use the master key.
5. **Switching engines**: use the settings UI or the config file.
   Switching triggers a backfill through the outbox. Leftover indices are
   not deleted automatically.
6. **Engine-seeded search**: with an engine attached, graph search
   (`includeLinked`), the agent `search_notes` tool and AI search
   grounding fuse engine and full-text hits deterministically, with no
   LLM. Any engine error falls back to the built-in full-text results.
   Results carry provenance.
7. Update the line-13 mention to "an optional Elasticsearch or Meilisearch
   engine".

## Verification

```bash
mkdir -p tmp/search-engine-fusion/P7
bash -c 'PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter "MeilisearchFactoryTests|SearchEngineFactoryTests" 2>&1 | tee tmp/search-engine-fusion/P7/factory.log; code=${PIPESTATUS[0]}; echo exit=$code; exit $code'
grep -nE "search:meilisearch:(up|down|status|test-live)" README.md | tee tmp/search-engine-fusion/P7/tasks.txt
grep -n "\"kind\": \"meilisearch\"" README.md | tee tmp/search-engine-fusion/P7/config.txt
grep -nE "/Users/|/home/" README.md; echo exit=$?
wc -l README.md
```

Expected evidence:

- Behavioral record: the factory run shows `exit=0` and the XCTest line
  `Executed N tests, 0 failures` with N > 0. These tests prove the
  documented facts: kind `meilisearch`, the `http://127.0.0.1:7700`
  identity format, and the `none`/`apiKey` auth modes with `basic`
  rejected.
- Supporting, non-behavioral checks:
  - all four task names appear in the README;
  - the config sample appears;
  - the absolute-path grep prints nothing and `exit=1`.

## Done criteria

- [x] README items 1-7 are present, with no secrets and no local paths.
- [x] The factory behavioral record has a positive XCTest count. Evidence
      is recorded in the progress log.

## Progress Log

- 2026-10-05: Plan created.
- 2026-10-05: Revised after Step 5 (SEF-PLAN-003): moved to wave 3 after
  P3 and added a factory test record as behavioral evidence.
- 2026-10-05: Updated `README.md` with the engine comparison, Meilisearch
  config and local task names, restricted-key guidance, engine switching and
  backfill behavior, engine-seeded retrieval and FTS fallback. The API-key
  guidance notes that `/health` is unauthenticated, so Test connection does
  not validate the key. `mise run search:meilisearch:{up,down,status,test-live}`
  names and the config grep matched; the `/Users/|/home/` grep printed
  nothing (exit 1); README is 623 lines.
- 2026-10-05: Required factory behavioral check is pending. Attempt 1
  (`tmp/search-engine-fusion/P7/factory.log`) exited 1 because the concurrent
  P6 GraphQL caller referenced `engineSeededSearchNotes` before its extension
  was visible to the build. Attempt 2
  (`tmp/search-engine-fusion/P7/factory-attempt-2.log`) exited 1 after P6 files
  appeared: AppGraphQL reported a fileprivate `.ok` access error and a missing
  `return`, and SwiftPM reported `GraphQLNoteSchemaContract.swift` modified
  during the build. These failures are outside P7 write paths; rerun the
  factory command once the shared P6 edits are stable. Neither attempt is
  passing behavioral evidence.
- 2026-10-05: Resumed the factory behavioral check after the shared tree
  stabilized. `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise
  exec -- swift test --filter "MeilisearchFactoryTests|SearchEngineFactoryTests"`
  exited 0 with 12 XCTest cases passed and 0 failures; full log:
  `tmp/search-engine-fusion/P7/factory-resume-1.log`. The README task and
  configuration greps matched, the absolute-path grep found no matches
  (exit 1), README remains 623 lines, and `git diff --check` passed. This
  resolves the earlier shared-tree compile blocker; the two failed attempts
  above are retained as historical evidence.
- 2026-10-05: Aligned the introduction with the plan's exact line-13 wording:
  “An optional Elasticsearch or Meilisearch engine”.
