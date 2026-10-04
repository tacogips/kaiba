# P10 Local tooling: docker compose Elasticsearch and mise search tasks

**Status**: Ready
**planId**: P10-local-tooling
**Wave**: 1
**dependsOn**: none
**Design Reference**: `design-docs/specs/search-engine-adapter.md` SE9
**Index**: `impl-plans/active/search-engine-adapter.md`

## Intent and context

Developers need a one-command local, single-node Elasticsearch 8.x to run
the gated live test and to try the feature. Docker is available locally
through colima (`docker compose`).

The existing mise task style is in `mise.toml`: `[tasks."<name>"]` with
`description` and `run = '''...'''`, and `.env` tables for
`PKG_CONFIG_PATH`. See the `test` and `anydoc:native` tasks.

## Non-goals

- Not for production use: the compose file is for local work only.
- No CI wiring. The live test stays gated and skipped in CI.
- No Swift or web code.

## writePaths

- `docker/elasticsearch/compose.yaml`
- `mise.toml`
- `impl-plans/active/search-engine-adapter-p10-local-tooling.md`

New files: `docker/elasticsearch/compose.yaml`.

## sharedPaths

none

## File-level changes

### `docker/elasticsearch/compose.yaml` (new)

- **Header comment.** It states that the file is for local development
  only, that security is disabled, and that the port is bound to loopback.
  It also refers to `design-docs/specs/search-engine-adapter.md`.
- **Service** `elasticsearch`:
  - Image `docker.elastic.co/elasticsearch/elasticsearch:8.19.0`. Verify the
    tag pulls. If it does not, use the newest `8.x.y` tag that pulls, and
    record the choice in the Progress Log.
  - `container_name: kaiba-elasticsearch`.
- **Environment**:
  - `discovery.type=single-node`
  - `xpack.security.enabled=false`
  - `xpack.security.http.ssl.enabled=false`
  - `ES_JAVA_OPTS=-Xms512m -Xmx512m`
- **Ports.** `"127.0.0.1:9200:9200"` only. Never `0.0.0.0`.
- **Volume.** The named volume `kaiba-elasticsearch-data` is mounted at
  `/usr/share/elasticsearch/data`, and a top-level `volumes:` declaration
  declares it.
- **Healthcheck.** The test is
  `curl -fsS http://localhost:9200/_cluster/health || exit 1`, with
  interval 5s, timeout 5s and 30 retries.

### `mise.toml`

Append four tasks. Do not modify the existing tasks.

| task | description | run |
| --- | --- | --- |
| `search:up` | "Start the local single-node Elasticsearch (local development only)" | `docker compose -f docker/elasticsearch/compose.yaml up -d --wait` |
| `search:down` | "Stop the local Elasticsearch (keeps the data volume)" | `docker compose -f docker/elasticsearch/compose.yaml down` |
| `search:status` | "Show local Elasticsearch cluster health" | `curl -fsS http://127.0.0.1:9200/_cluster/health` |
| `search:test-live` | "Run the gated Elasticsearch live integration test against the local cluster" | `KAIBA_ELASTICSEARCH_URL=${KAIBA_ELASTICSEARCH_URL:-http://127.0.0.1:9200} swift test --filter ElasticsearchLive` |

`search:test-live` also gets `depends = ["anydoc:native"]` and an
`[tasks."search:test-live".env]` table with
`PKG_CONFIG_PATH = "{{config_root}}/.build/anydoc-native/host/pkgconfig"`,
matching the `test` task.

## Pitfalls

- Bind only to `127.0.0.1`. The factory rejects plain `http` to non-loopback
  hosts, and an open port would expose an unauthenticated cluster.
- `search:down` must not pass `-v`, so the named volume survives.
- Do not reorder or reformat the existing `mise.toml` content.
- No machine-local absolute paths.

## Tests

No unit tests. Use command-level checks.

## Verification

```bash
bash -c 'mkdir -p tmp/search-engine-adapter/P10 && docker compose -f docker/elasticsearch/compose.yaml config 2>&1 | tee tmp/search-engine-adapter/P10/compose-config.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P10 && mise tasks ls 2>&1 | grep "search:" | tee tmp/search-engine-adapter/P10/tasks.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P10 && mise run search:up 2>&1 | tee tmp/search-engine-adapter/P10/up.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P10 && mise run search:status 2>&1 | tee tmp/search-engine-adapter/P10/status.log; echo exit=${PIPESTATUS[0]}'
bash -c 'mkdir -p tmp/search-engine-adapter/P10 && mise run search:down 2>&1 | tee tmp/search-engine-adapter/P10/down.log; echo exit=${PIPESTATUS[0]}'
grep -n "127.0.0.1:9200:9200" docker/elasticsearch/compose.yaml
```

Expected evidence:

- `compose config` exits 0.
- 4 `search:` tasks are listed.
- `up` and `status` exit 0, and `status.log` shows `"status":"green"` or
  `"yellow"`.
- `down` exits 0.

If Docker or colima is not running, record `blocked: docker unavailable`
for the up, status and down commands. Do not record that as passed. P11
retries them.

## Done criteria

- [x] The compose file has a pinned 8.x image, single-node, security off,
      a loopback-only port, a named volume and a healthcheck.
- [x] The four mise tasks exist, and the existing tasks are unchanged.
- [x] The verification commands show `exit=0`, or have explicit Docker
      blockers recorded.

## Progress Log

- 2026-10-04: Plan created.
- 2026-10-04: Implemented P10. Pulled the pinned Elasticsearch 8.19.0 image
  successfully. Compose config, task listing, loopback bind check, and
  `search:up`, `search:status` (`green`), and `search:down` all exited 0.
  `search:down` omitted `-v`; the named volume was created and retained by
  the Compose project. Complete logs are in
  `tmp/search-engine-adapter/P10/attempt-1/`. Final authored-file SHA-256:
  compose `1f3cf5133f04fad6086950417bcef21e4f86ff288b32b472a6ada7c509aa3840`,
  mise `36e25bb3a3b544fd3b96bf0672693e395f92c39743aba928dba499156c566afc`.
- 2026-10-04: Re-ran the command-level checks against the current source.
  Compose config, task listing, loopback bind, startup healthcheck, green
  single-node status, teardown and volume-retention checks all exited 0.
  Complete logs are in `tmp/search-engine-adapter/P10/attempt-2/`. Compose
  and mise SHA-256 remain
  `1f3cf5133f04fad6086950417bcef21e4f86ff288b32b472a6ada7c509aa3840` and
  `36e25bb3a3b544fd3b96bf0672693e395f92c39743aba928dba499156c566afc`.
- 2026-10-04: Step 6 resume current-source verification is in
  `tmp/search-engine-adapter/P10/attempt-3/`. Compose config, all four task
  listings, loopback binding, `search:up`, green `search:status`,
  `search:down`, and retained named-volume checks exited 0. The additional
  `search:test-live` attempt exited 1 during Swift compilation because the
  shared tree's `GraphQLNoteGraphQLService` lacks the P6 methods
  `searchEngineCapability`, `engineSearchNotes`, and `relatedNotes`; the live
  tests did not execute. This is downstream combined-tree integration work
  for P11, not a P10-owned command-level criterion. The local service was
  stopped after the attempt and its data volume remains.
- 2026-10-04: Attempt-4 current-source verification is in
  `tmp/search-engine-adapter/P10/attempt-4/`. Compose config, the four task
  listings and `anydoc:native` dependency, loopback binding, startup,
  green single-node status, live Elasticsearch integration (1 test passed,
  0 failures), teardown, volume retention and `git diff --check` all exited
  0. This combined-tree live-test pass supersedes the attempt-3 compile
  failure; the local service is stopped and its named data volume remains.
