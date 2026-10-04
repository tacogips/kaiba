# Search Engine Adapter

## Status

Proposed (2026-10-04)

## Traceability

- Default retrieval path, which this design leaves unchanged:
  `design-docs/specs/note-retrieval-fusion.md` (SQLite FTS5 `note_fts`,
  lexical fusion) and `design-docs/specs/kaiba-note.md` (search, graph).
- Access rules applied unchanged: `design-docs/specs/library.md`,
  `design-docs/specs/multi-user.md`.
- Credential pattern mirrored: the Turso `authTokenEnvironmentVariable` field
  in `Sources/AppCore/KaibaConfiguration.swift`.
- Client surfaces: `design-docs/specs/kaiba-client-sdk.md` (hand-written
  operations in `Sources/KaibaClient`), `design-docs/specs/web-chatbook-ui.md`.
- Decisions and open questions: `design-docs/user-qa/search-engine-adapter.md`.
- Implementation plan: `impl-plans/active/search-engine-adapter.md` (written
  in the planning step).

## Problem

Kaiba searches notes only through the SQLite FTS5 trigram index. Operators
who already run a search engine want two things it serves better: full-text
search with engine-grade ranking and highlighting, and a "related notes" list
for the note that is open. Both must stay optional. A store with no engine
configured must behave exactly as it does today.

## Scope

In scope:

- SE1: an AppCore `SearchEngine` protocol, its value types, and a factory
  that builds an adapter from configuration.
- SE2: an optional `searchEngine` section in `config.json`.
- SE3: a durable sync outbox that keeps the engine in step with note writes
  and is never able to fail one.
- SE4: an access-control rule: the engine query is filtered, and every hit is
  re-checked against the store.
- SE5: GraphQL `searchEngineCapability`, `engineSearchNotes` and
  `relatedNotes`, plus the matching KaibaClient operations.
- SE6: the CLI commands `kaiba search-engine status|sync|reindex`.
- SE7: web client changes: capability-gated search and a Related notes
  section.
- SE8: an Elasticsearch 8.x adapter over URLSession.
- SE9: local development tooling: a docker compose file and
  `mise run search:*` tasks.

Out of scope: other engines, vector/embedding search, feeding engine hits
into the FTS fusion ranking, the agent `search_notes` tool, the
`NoteSearchPopup` link picker, a GraphQL admin reindex mutation, and
automatic deletion of old indices.

## Invariants

1. **Unconfigured means unchanged.** With no `searchEngine` section, or with
   `enabled: false`, no adapter is built, no network call is made,
   `searchNotes` and every `NoteSearch*.swift` path run exactly as today,
   `searchEngineCapability.enabled` is `false`, and the web client hides
   every engine surface. The only store-level difference is one added
   statement per note write. It inserts nothing unless the store has been
   activated (SE3).
2. **Writes never depend on the engine.** Engine calls never run inside a
   store transaction. A write only records a row in a local outbox table, in
   the same transaction as the note change.
3. **The store is the authority on access.** An engine hit reaches a caller
   only if the store re-check in SE4 returns it. Index freshness never
   affects who may see a note. It can only make a result list shorter.
4. **The engine indexes what `note_fts` indexes.** The document set and the
   title, body, tag and context text are derived the same way as
   `refreshFTS`/`currentFTSPayload` (`Sources/AppCore/NoteSearchIndex.swift`).
5. **Callers see only the protocol.** NoteService, AppGraphQL, AppServer and
   AppCLI use `any SearchEngine`. Elasticsearch types, JSON and URLs are
   private to the adapter files.

## SE1. Protocol and value types (AppCore)

New file `Sources/AppCore/SearchEngine.swift`. All types are `Sendable` and
`Equatable`.

```swift
public protocol SearchEngine: Sendable {
  /// Stable name of the index generation this adapter writes, for example
  /// "elasticsearch:kaiba-notes-v1". A change triggers a backfill (SE3).
  var indexIdentity: String { get }
  func health() async throws -> SearchEngineHealth
  /// Idempotent. Creates the versioned index with its mapping if absent.
  func ensureIndex() async throws
  /// Bulk upsert/delete. One result per operation, in order.
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult]
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit]
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit]
}
```

A protocol extension adds single-document convenience methods,
`upsert(_ document:)` and `delete(noteId:)`, built on `apply`. Adapters do not
implement them.

Value types:

- `SearchIndexDocument`: `noteId`, `notebookId`, `libraryId`, `ownerUserId`,
  `title`, `body` (the `noteRetrievalText` result), `tagIds` (direct tags),
  `tagNames`, `context` (the `ftsContextPayload` result), `isLongTermMemory`,
  `createdAt`, `updatedAt`.
- `SearchIndexOperation`: `.upsert(SearchIndexDocument)` or
  `.delete(NoteID)`.
- `SearchIndexOperationResult`: `noteId` and `outcome`, which is
  `.succeeded` or `.failed(String)`. Deleting a document that is already
  absent counts as `.succeeded`.
- `SearchEngineFilter`:
  - `libraryIds: [LibraryID]?`. `nil` means unrestricted. The service never
    sends `[]`: it answers that case with an empty result and does not call
    the engine.
  - `ownerUserId: UserID?`
  - `notebookId: NotebookID?`
  - `tagIds: [TagID]`, matched any-of. The service expands each tag to its
    descendant ids first, with `expandedTagFilterIds(names:)`.
  - `excludesLongTermMemory: Bool`
  - `excludedNoteIds: [NoteID]`
- `SearchEngineQuery`: `text`, `filter`, `from`, `size`.
- `SearchEngineRelatedQuery`: `likeText`, `filter`, `size`. `likeText` is
  the source note's title and retrieval text, read from the store and capped
  at 4000 characters, so the query never depends on whether the source note
  has been indexed yet. The filter's `excludedNoteIds` contains the source
  note.
- `SearchEngineHit`: `noteId`, `score: Double`, and `highlight: String?`
  (plain text, no markup).
- `SearchEngineHealth`: `isAvailable: Bool` and `detail: String`.
- `SearchEngineError`:
  - `.unavailable(String)`: a transport failure or timeout.
  - `.rejected(status: Int, reason: String)`
  - `.invalidResponse(String)`

  Messages carry only the HTTP status and the engine's error type and
  reason. They never include headers, credentials or URL userinfo.

Factory, in `Sources/AppCore/SearchEngineFactory.swift`:
`SearchEngineFactory.make(configuration: KaibaSearchEngineConfiguration?,
environment: [String: String]) throws -> (any SearchEngine)?`.

- It returns `nil` when the section is absent or `enabled == false`.
- It throws `KaibaConfigurationError` for a bad kind, URL, prefix or
  credential, as described in SE2.

`NoteService` gains `public var searchEngine: (any SearchEngine)?`, which
defaults to `nil`. Scoped copies of the service inherit it.

## SE2. Configuration

`KaibaConfiguration` gains `searchEngine: KaibaSearchEngineConfiguration?`
under the JSON key `searchEngine`, decoded with `decodeIfPresent`. It is a
flat struct, following the `KaibaOCRConfiguration` style:

| field | type | rule |
| --- | --- | --- |
| `kind` | String | Required. Only `"elasticsearch"` is accepted. Anything else makes the factory throw `invalid("searchEngine.kind")`. |
| `enabled` | Bool? | Defaults to `true`. `false` turns the feature off without deleting the section. |
| `url` | String | Required. The scheme must be `http` or `https`. Userinfo is rejected. `http` is allowed only for loopback hosts (`localhost`, `127.0.0.1`, `::1`). Any violation throws `invalid("searchEngine.url")`. |
| `indexPrefix` | String? | Defaults to `kaiba`. Must match `^[a-z0-9][a-z0-9_-]{0,63}$`, otherwise `invalid("searchEngine.indexPrefix")`. |
| `apiKeyEnvironmentVariable` | String? | The environment-variable name of an Elasticsearch API key. It is sent as `Authorization: ApiKey <value>`. |
| `usernameEnvironmentVariable`, `passwordEnvironmentVariable` | String? | Names for Basic auth. Both or neither must be set. |

Validation rules:

- Setting an API key together with username/password throws
  `invalid("searchEngine.credentials")`.
- A variable that is named but missing from the environment throws
  `missingEnvironmentVariable(name)`, the same as Turso does.
- Setting no credential fields at all means no `Authorization` header. This
  is the local compose case.

Factory errors are fatal at server start and for `kaiba search-engine`
commands. Other CLI commands never build the adapter, so a bad or missing
engine credential cannot break them.

Sample, which also goes in the README:

```json
{
  "searchEngine": {
    "kind": "elasticsearch",
    "url": "http://127.0.0.1:9200",
    "indexPrefix": "kaiba"
  }
}
```

A remote cluster adds `"apiKeyEnvironmentVariable": "KAIBA_ELASTICSEARCH_API_KEY"`
and uses an `https` URL.

## SE3. Indexing and consistency: durable outbox

Strategy: a durable, coalescing outbox in the note store, filled inside the
write transaction and drained after commit. A failed push retries with
backoff and is never dropped. Best-effort indexing alone was rejected for
three reasons:

- About fifteen write sites change indexed text: create, update, tag apply
  and remove, tag reparent, undo/redo, OCR, translation, agent chat, and
  long-term memory.
- They do not report the note ids they touched in a uniform way.
- A push lost to an engine outage would stay lost until someone ran a manual
  reindex.

All of those sites already call `refreshFTS`, and every note deletion goes
through `deleteNoteRows`. Hooking those two choke points therefore covers
every indexed-text write. The two notebook library changes (`moveNotebook`
and the tag-memo rehome) bypass `refreshFTS` and are hooked separately in
the call sites below.

### Schema (store version 23)

```sql
CREATE TABLE IF NOT EXISTS search_engine_sync_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  index_identity TEXT NOT NULL,
  activated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS search_index_outbox (
  note_id TEXT PRIMARY KEY,
  generation INTEGER NOT NULL DEFAULT 1,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TEXT,
  last_error TEXT,
  claim_token TEXT,
  claimed_until TEXT
);
```

- There are no foreign keys. An outbox row must outlive its note so the
  delete can still be pushed.
- `NoteStoreSchema.prepare` creates both tables right after
  `note_schema_version` and before `requireSupportedVersion`. The upgrade
  chain (v19/v20/v21 to v22) calls `refreshFTS`, which runs the enqueue
  statement, so the tables must exist first.
- `upgradeToVersion23` only records version 23. Newest-version branches 19,
  20, 21 and 22 each continue to 23.
- `currentVersion` becomes 23. `NoteStoreSchemaCanonicalTests` and a new
  `NoteStoreSchemaVersion23Tests` cover a fresh store and a v22 upgrade.
- The same path runs for the Turso driver, because `NoteService.init` calls
  `NoteStoreSchema.prepare` for every driver.

### Enqueue (inside the write transaction)

`enqueueSearchEngineSync(noteIds:in:)` lives in the new file
`Sources/AppCore/SearchEngineSyncOutbox.swift`:

```sql
INSERT INTO search_index_outbox (note_id) SELECT ?
WHERE EXISTS (SELECT 1 FROM search_engine_sync_state)
ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
  attempts = 0, next_attempt_at = NULL, last_error = NULL
```

- **Not activated:** while `search_engine_sync_state` is empty the statement
  inserts nothing. This holds for every store that has never had an engine
  configured.
- **Coalescing:** the table holds at most one row per note.
- **Concurrent pushes:** a re-enqueue keeps any existing claim, so two
  processes never push the same note at once.

Call sites, each one line:

- the end of `refreshFTS`, in `NoteSearchIndex.swift`;
- `deleteNoteRows`, in `NoteService.swift`, which stays under 1000 lines;
- `moveNotebook`, in `NoteService+Libraries.swift`, for every note of the
  moved notebook;
- the library rehome branch of `ensureTagMemoNotebook(tagId:)`, in
  `NoteService+TagDetail.swift`, for every note of the rehomed notebook. It
  runs `UPDATE notebooks SET library_id = ?` when the tag memo's source
  library changes.

`moveNotebook` and the tag-memo rehome are the two notebook `library_id`
updates that do not pass through `refreshFTS`, and the indexed `libraryId`
of every note in the notebook changes with them. Notebooks cannot be renamed
or change owner, so there is no other notebook-scope trigger. Without the
rehome call site, notes of a rehomed tag memo would keep a stale `libraryId`
in the engine. A caller who reaches only the new library would then miss
them in engine search and `relatedNotes` until each note is written again,
and the store re-check cannot recover such false negatives.

`NoteService.swift` gets no other changes. Every new service logic goes in
`NoteService+SearchEngine*.swift` extensions.

### Activation and backfill

`activateSearchEngineSync(indexIdentity:)` runs in one transaction:

- It upserts the state row.
- If the row was absent, or its `index_identity` differs from the adapter's,
  it enqueues every note:
  `INSERT INTO search_index_outbox(note_id) SELECT note_id FROM notes ...`
  with the same conflict clause as above.

This one rule covers first activation, a mapping-version bump and an
`indexPrefix` change.

It is called at server start when an engine is configured, and by every
`kaiba search-engine` command. Removing the configuration does not clear the
state row. Writes keep enqueueing, but the outbox stays bounded at one row
per note, so the backlog drains when the engine is configured again. A
detach command is recorded as an open question in user-qa.

### Drain (`SearchIndexSynchronizer`, AppCore)

`drain(engine:batchSize: 100)` runs one pass:

1. **Claim.** In a write transaction, claim up to 100 due rows (no
   `next_attempt_at`, or one that has passed), skipping rows whose claim is
   still unexpired. Set a fresh `claim_token` and set `claimed_until` to now
   plus 60 seconds, which is longer than the 30-second bulk timeout. Remember
   each row's `generation`.
2. **Read.** Outside any transaction, build a `SearchIndexDocument` from the
   store for each claimed note. A missing note becomes `.delete(noteId)`.
3. **Push.** Call `engine.apply(operations)`.
4. **Settle.** In a write transaction, per note:
   - **Success:** `DELETE ... WHERE note_id = ? AND claim_token = ? AND
     generation = ?`. If the generation moved during the flight, the row
     survives and the claim is released, so the newer state is pushed on a
     later pass.
   - **Failure:** release the claim, increment `attempts`, set
     `next_attempt_at = now + min(5s * 2^(attempts-1), 1h)`, and store
     `last_error` truncated to 500 characters.

   If `apply` throws instead of returning per-operation results, the whole
   batch counts as failed.
5. **Report.** Return `SearchIndexDrainReport` with `pushed`, `failed`,
   `remaining` and `remainingDue`.

Rows are never dropped after repeated failures. Retries continue at the
1-hour cap until they succeed. `status` reports the backlog (SE6).

### Who drains

- **Server.** `KaibaServerRuntime` starts one sync loop task when an engine
  is configured. The loop:
  - runs `ensureIndex` and activation first, retrying on the loop cadence if
    the engine is down;
  - then drains on a fixed 15-second tick, and immediately after any
    `NoteChangeEvent`, debounced to 1 second;
  - stops with the server.

  The change-event hookup is a fan-out observer that wraps the existing
  `NoteChangeFeedObserver`. Writes that publish no event (for example
  `moveNotebook` or CLI writes from another process) are picked up by the
  tick. There is no new configuration knob for the cadence.
- **CLI.** `kaiba search-engine sync` and `reindex` drain in the foreground
  (SE6). Ordinary CLI writes only enqueue, and the next server tick or `sync`
  pushes them.

Visibility lag: a write served by the server shows up in engine results
after the drain plus Elasticsearch's 1-second refresh. Until then, engine
search simply does not see it. `searchNotes` is unaffected.

## SE4. Access control

Engine-backed reads apply the scope twice.

1. **Engine filter.**
   - The service builds the same `NoteSearchScope` that `searchNotes` builds:
     `notebookId`, `reachableLibraryIds`, `actingUserId`,
     `excludesLongTermMemory`, `excludesPendingNotebookIngests`. Both paths
     call one shared helper, `makeNoteSearchScope(notebookId:in:)`, which is
     extracted from `NoteService+Search.swift` with no behavior change.
   - The service maps that scope to a `SearchEngineFilter`.
     `reachableLibraryIds == []` returns `[]` without calling the engine.
   - The pending-ingest state can change without a note write, so it is not
     indexed. Only the store re-check enforces it.
2. **Store re-check.** `scopedNoteIds(_ ids:, scope:)` runs one SQL query
   over the hit ids. It uses the same `append*Predicate` helpers as
   `searchNotesInDatabase`: library, owner, long-term memory, pending
   ingest, notebook and created-at. Hits it does not return are dropped,
   which covers stale filter fields, deleted notes and orphaned documents.
   Survivors are hydrated with `requireNotes`, keep the engine's order, and
   carry a snippet from the engine highlight. Without a highlight, the
   existing `snippet(from:query:)` is used.

`relatedNotes(noteId:)` first loads the source with `requireNote`, which
enforces reach, ownership and ingest finalization. If that fails the result
is `not_found`, indistinguishable from a missing note. The source id is
excluded in the engine query and again after the re-check.

Pagination for `engineSearchNotes`:

- The service asks the engine for hits `[0, offset + limit + 20)`, re-checks
  them, then returns the slice `[offset, offset + limit)`.
- `limit` must be in `0...200` and `offset` in `0...1000`. Out-of-range
  values are rejected with `invalidVariable`, matching the existing
  executor rule; they are not clamped.
- The response carries no total-hit count, so engine counts cannot reveal
  documents the caller cannot see.

## SE5. GraphQL and KaibaClient

The `type Query` lines in `GraphQLContractProjector.schemaContract` gain:

```graphql
searchEngineCapability: SearchEngineCapabilityPayload!
engineSearchNotes(query: String!, notebookId: String, tagFilter: [String!], limit: Int, offset: Int): EngineNoteSearchQueryPayload!
relatedNotes(noteId: String!, limit: Int): EngineNoteSearchQueryPayload!
```

The types go in `graphQLNoteSchemaContract`:

```graphql
type SearchEngineCapabilityPayload { result: ControlPlaneResult!, enabled: Boolean! }
type EngineNoteHit { note: Note!, snippet: String!, score: Float! }
type EngineNoteSearchQueryPayload { result: ControlPlaneResult!, value: [EngineNoteHit!] }
```

Behavior:

- `searchNotes` is unchanged. Engine search is a separate field, so the
  default path cannot regress and its score semantics, where a lower BM25
  rank is better, are not mixed with engine scores, where higher is better.
- `searchEngineCapability.enabled` is `true` exactly when an adapter is
  attached. It makes no network call. Any caller allowed to query may read
  it.
- `engineSearchNotes` limits are described in SE4. An empty or
  whitespace-only `query` is rejected with `invalid_request`.
- `relatedNotes` accepts `limit` in `0...20` and defaults to 8.
- With no engine, both fields return `accepted: false` with status
  `feature-disabled`.
- An engine failure returns `accepted: false` with status
  `search-engine-unavailable` and the public diagnostic
  `search engine unavailable`. There is no silent fallback inside the
  server; the client decides what to do.
- New fields are registered in:
  - `supportedNoteGraphQLFields`
  - `noteGraphQLQueryFields`
  - `noteGraphQLRootSelectionTypes`
  - `noteGraphQLSelectionFields`
  - the document executor dispatch
- The service methods live in the new file
  `NoteGraphQLService+SearchEngine.swift`, because `NoteGraphQLService.swift`
  is already 956 lines.
- `NoteGraphQLSchemaInventoryTests`, `GraphQLSchemaAuthorizationTests` and
  the KaibaClient schema/typed-operation contract tests are updated.

KaibaClient operations are hand-written. The new file
`Sources/KaibaClient/KaibaOperations+SearchEngine.swift` adds
`searchEngineCapability()`, `engineSearchNotes(...)` and
`relatedNotes(noteId:limit:)`. The new models go in `KaibaModels.swift`.

## SE6. CLI

`kaiba search-engine <status|sync|reindex>` is an async command in
`Sources/AppCLI/SearchEngineCommand.swift`, following the `AICommand`
pattern. Each subcommand loads the configuration, builds the adapter through
the factory, and calls `requireStoreAdministrator()`. If no engine is
configured, it exits with code 2 and the message
`search engine is not configured`.

- `status`:
  - Prints `kind`, `indexIdentity`, the health result, the pending outbox
    count, the count of rows with `attempts > 0`, and the oldest due time.
  - Never prints the URL's credentials or any secret.
  - `--json` gives the same fields as JSON.
  - Exits 0 even when the engine is unhealthy.
- `sync`: runs `ensureIndex`, then activation, then drains until no due rows
  remain or a pass makes no progress. It prints the totals and exits 1 if
  any rows failed.
- `reindex`: does the same as `sync`, but first re-enqueues every note,
  which makes it the backfill. It does not delete stale documents.
  Re-check makes orphaned documents harmless, and the README explains how
  to delete an index by hand.

There is no GraphQL admin reindex. The server already backfills on activation
and on an identity change, so a remote admin action would add an
authorization surface without a requirement behind it.

## SE7. Web client

- **Capability.** After connecting, the app store loads
  `searchEngineCapability` once per server connection into
  `searchEngineEnabled`, which defaults to `false`. Any error keeps it
  `false`.
- **Search.** For the `grep` method, `SearchView` calls `engineSearchNotes`
  when `searchEngineEnabled` is true, and `searchNotes` otherwise. If the
  engine call returns `search-engine-unavailable` or `feature-disabled`, the
  view re-runs the query through `searchNotes` and shows the status line
  `Search engine unavailable; showing built-in results`. Results render
  through the existing row markup, with the note title and plain-text
  snippet. The agentic method and `NoteSearchPopup` do not change.
- **Related notes.** A new `RelatedNotesSection` component renders in the
  right pane's Links tab, under `LinkedDocsTab`, only when
  `searchEngineEnabled` is true and the pane is in note mode.
  - It loads `relatedNotes(noteId, limit: 8)` when the open note changes,
    discarding stale responses with a generation counter, as `SearchView`
    does.
  - It lists each note's title as a button that navigates to that note
    through the same navigation `LinkedDocsTab` uses.
  - It shows `No related notes` when the list is empty, and
    `Related notes unavailable` on an error.
  - When the capability is disabled it renders nothing.
- **Client.** `web/src/notes/client.ts` and `types.ts` gain the three
  operations.
- **Tests.**
  - `RelatedNotesSection.integration.tsx` covers a hidden panel when
    disabled, a list with navigation when enabled, and the error text.
  - A `SearchView` test covers that the engine is used when enabled, that
    `searchNotes` is used when disabled, and the fallback when unavailable.
  - Run `mise run web:check` and `mise run tauri:check`. No Rust change is
    expected.

## SE8. Elasticsearch adapter

All adapter code lives in `Sources/AppCore/Elasticsearch*.swift`, with no new
SwiftPM dependencies. `FoundationNetworking` is imported under
`#if canImport`, as `TursoHTTPDatabase.swift` does.

- **Transport.** An internal `ElasticsearchHTTPTransport` protocol, with
  `send(URLRequest) async throws -> (Data, HTTPURLResponse)`, is implemented
  over `URLSession`. Tests inject a mock. Query requests time out after 10
  seconds and bulk requests after 30.
- **Index.** The index is the concrete name `<indexPrefix>-notes-v1`, and
  `indexIdentity` is `elasticsearch:<indexPrefix>-notes-v1`. A future
  mapping change bumps `v1`, which triggers the SE3 backfill. There are no
  aliases.
- **`ensureIndex`.** `HEAD /<index>` returns 200 when the index exists. On
  404 the adapter sends `PUT /<index>` with settings and mappings. A 400
  `resource_already_exists_exception` counts as success.
- **Mapping.**
  - `keyword` fields: `note_id`, `notebook_id`, `library_id`,
    `owner_user_id`, `tag_ids`.
  - `boolean`: `long_term_memory`.
  - `date`: `created_at`, `updated_at`.
  - `text` fields: `title`, `body`, `tags`, `context`.
  - `dynamic: strict`.
  - Text fields use the built-in `cjk` analyzer. It needs no plugins, makes
    bigrams of CJK text and tokenizes Latin text normally. Kuromoji is
    recorded as a user-qa option.
  - Index settings: only the analysis configuration. Shard and replica
    counts keep the cluster defaults. A yellow single-node cluster is
    healthy (see Health below).
- **Bulk.** `POST /_bulk` with an NDJSON body of `index` actions (`_id` =
  note id) and `delete` actions.
  - Per-item errors become `.failed(type: reason)`.
  - A `delete` that returns 404 counts as success.
  - HTTP 401/403 becomes `.rejected`, and 5xx or a transport error becomes
    `.unavailable`. Either way the whole call throws.
- **Search.**
  - The query is a `bool` with a `must` clause of `multi_match` over
    `title^3, body, tags^2, context` with `operator: or`. These weights
    mirror the FTS BM25 weights.
  - `filter` uses `terms`/`term` clauses for library, owner, notebook and
    tags.
  - `must_not` excludes long-term memory and `excludedNoteIds`.
  - Highlighting runs on `body` and `title`, with `fragment_size: 160`,
    `number_of_fragments: 1`, and empty `pre_tags`/`post_tags`, so snippets
    are plain text and safe to render.
  - `_source` is limited to `note_id`.
- **Related.** `more_like_this` over the same four fields with `like:
  likeText`, `min_term_freq: 1`, `min_doc_freq: 1` and `max_query_terms: 25`,
  inside the same filter `bool`.
- **Health.** `GET /_cluster/health`. A `red` status or any error means
  `isAvailable: false`.

Tests:

- `ElasticsearchSearchEngineTests` uses the mocked transport to check exact
  request methods, paths and bodies, including the NDJSON, plus per-item and
  HTTP error mapping, idempotent `ensureIndex`, and the auth header for
  each credential mode.
- `ElasticsearchLiveTests` is skipped unless `KAIBA_ELASTICSEARCH_URL` is
  set. It uses a unique `indexPrefix` per run, runs ensureIndex, upsert,
  refresh, search, related and delete, and deletes its index when done.

## SE9. Local development

- **Compose file.** `docker/elasticsearch/compose.yaml` runs one service on a
  pinned `docker.elastic.co/elasticsearch/elasticsearch:8.x.y` tag; the
  implementer verifies the tag pulls. It sets:
  - `discovery.type=single-node`
  - `xpack.security.enabled=false`
  - `ES_JAVA_OPTS=-Xms512m -Xmx512m`
  - port `127.0.0.1:9200:9200`, loopback only
  - the named volume `kaiba-elasticsearch-data`
  - a `_cluster/health` healthcheck

  A comment, and the README, state that disabled security is for local use
  only.
- **mise tasks.**
  - `search:up` runs `docker compose -f docker/elasticsearch/compose.yaml
    up -d --wait`.
  - `search:down` runs `down` and keeps the volume.
  - `search:status` runs `curl -fsS http://127.0.0.1:9200/_cluster/health`.
  - `search:test-live` runs the gated test with
    `KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200` and the existing
    `PKG_CONFIG_PATH`.

## Test plan (Swift, AppCore unless noted)

- **`SearchEngineSyncTests`**, using an in-memory `FakeSearchEngine` in
  Tests:
  - Before activation, writes leave the outbox empty, and the default
    `searchNotes` results are identical to a store without the feature.
  - After activation, create, update, tag, reparent, undo, delete, notebook
    delete, `moveNotebook` and tag-memo notebook rehome each enqueue the
    right ids.
  - A drain pushes upserts and deletes.
  - An engine that throws leaves the note write committed, and its rows
    retry with backoff.
  - A generation bump during a flight keeps the row.
  - A changed index identity triggers a backfill.
- **`SearchEngineAccessTests`**: library, owner, long-term-memory and
  pending-ingest filtering apply both to the filter sent to the engine and
  to the re-check. The re-check is exercised with a fake that ignores
  filters. `relatedNotes` returns `not_found` for an unreachable source and
  never returns the source note. `reachableLibraryIds == []` makes no engine
  call.
- **`KaibaSearchEngineConfigurationTests`**: absent or disabled config
  yields `nil`; an unknown kind, a non-loopback `http` URL, userinfo, a bad
  prefix, or mixed credentials throw; a missing environment variable throws
  `missingEnvironmentVariable`.
- **AppGraphQL tests**: capability true/false, `feature-disabled`, bounds
  validation, `search-engine-unavailable`, and the schema inventory.
- **KaibaClient tests**: typed operations against the contract.

## Verification

- `mise run build`
- `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test --filter Search`
- `mise run test`
- `mise run lint`
- `mise run web:check`
- `mise run tauri:check`
- `mise run search:up`, then `mise run search:test-live`, then
  `mise run search:down`

## Rollout

- **Existing stores.** Upgrading to store v23 creates two empty tables.
  Nothing else changes until an engine is configured.
- **First server start with an engine.** The server creates the index and
  enqueues every note, then the backfill drains in batches of 100.
  `kaiba search-engine status` shows progress.
- **Turning the engine off.** Remove the section or set `enabled: false`.
  The capability turns false, the web client hides the panel, and the outbox
  keeps one row per changed note until the engine is enabled again.
