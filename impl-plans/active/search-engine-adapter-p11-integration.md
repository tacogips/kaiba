# P11 Integration: docs, live test, full verification, serial repair

**Status**: Ready
**planId**: P11-integration
**Wave**: 4
**dependsOn**: P1-core-contract, P2-store-outbox, P3-elasticsearch-adapter, P4-sync-drain, P5-engine-query-service, P6-graphql-client, P7-cli, P8-server-sync-loop, P9-web-client, P10-local-tooling
**Design Reference**: `design-docs/specs/search-engine-adapter.md` (all sections, Verification, Rollout)
**Index**: `impl-plans/active/search-engine-adapter.md`

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
- `impl-plans/active/search-engine-adapter.md`
- `impl-plans/active/search-engine-adapter-p11-integration.md`

## sharedPaths (serial repair only, with logged hashes)

- `Sources/AppCore`
- `Sources/AppGraphQL`
- `Sources/AppServer`
- `Sources/AppCLI`
- `Sources/KaibaClient`
- `Tests/AppCoreTests`
- `Tests/AppGraphQLTests`
- `Tests/AppServerTests`
- `Tests/KaibaClientTests`
- `web/src`

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
     (`curl -X DELETE http://127.0.0.1:9200/<prefix>-notes-v1`) and run
     `kaiba search-engine reindex`.
5. A link to `design-docs/specs/search-engine-adapter.md`.

Use no machine-local absolute paths and no emojis.

### `impl-plans/active/search-engine-adapter.md`

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
- **Cleanup.** Run `mise run search:down` after the live test, even when it
  fails.

## Verification

```bash
mise run build
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Search 2>&1 | tee tmp/search-engine-adapter/P11/search-filter.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter NoteStoreSchema 2>&1 | tee tmp/search-engine-adapter/P11/schema.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run lint 2>&1 | tee tmp/search-engine-adapter/P11/lint.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run web:check 2>&1 | tee tmp/search-engine-adapter/P11/web-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run tauri:check 2>&1 | tee tmp/search-engine-adapter/P11/tauri-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise run check 2>&1 | tee tmp/search-engine-adapter/P11/full-check.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run search:up 2>&1 | tee tmp/search-engine-adapter/P11/search-up.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run search:test-live 2>&1 | tee tmp/search-engine-adapter/P11/live.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P11 && mise run search:down 2>&1 | tee tmp/search-engine-adapter/P11/search-down.log; echo exit=${PIPESTATUS[0]}'
bash -c 'find Sources Tests -name "*.swift" -exec wc -l {} + | sort -n | tail -6'
bash -c 'LC_ALL=C grep -rnP "[^\x00-\x7F]" README.md docker/elasticsearch/compose.yaml Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift || echo ascii-ok'
bash -c '! grep -rn "/Users/\|/home/" README.md docker design-docs/specs/search-engine-adapter.md impl-plans/active/search-engine-adapter.md Sources Tests web/src'
git status --short
git diff --check
```

Expected evidence:

- `exit=0` for every Swift, lint, web, tauri and full-check run.
- `live.log` shows the `ElasticsearchLiveTests` cases executed, not
  skipped, and passing. Otherwise record `blocked` with the Docker error.
- The largest Swift file is under 1000 lines.
- `ascii-ok` is printed.
- The absolute-path guard exits 0.
- `git status` lists only planned files and logged repairs, and `.riela/`
  is unchanged.
- `git diff --check` is clean.

## Done criteria

- [ ] The README section exists with the sample configuration and the
      local-only security note.
- [ ] The full check passes, and the live test passes, or is explicitly
      `blocked` for lack of Docker.
- [ ] Every cross-plan repair is logged with hashes. No high or mid issue
      remains unreported.
- [ ] The index plan status and evidence are updated. Nothing is committed.

## Progress Log

- 2026-10-04: Plan created.
