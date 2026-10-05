# Search Engine Adapter

## Status

- SE1-SE9: accepted (2026-10-04) and implemented. The base was
  checkpointed in b466ced. The CLI (SE6), the server sync loop (SE3 "Who
  drains") and the integration pass were completed in session-264.
- D0-D5 (the delta at the end of this document): accepted (2026-10-04,
  comm-003772) and implemented in session-264 (2026-10-05). The
  integration review accepted all 21 plans (comm-003910). They extend
  SE1-SE9. Where a delta section changes an earlier rule, it says so
  explicitly, and the earlier text stays as the base record.
- F1-F6 (engine-seeded retrieval, the unified reranker and the Meilisearch
  adapter): proposed (2026-10-05) in
  `design-docs/specs/design-search-engine-fusion.md`. It changes SE1 "Out
  of scope", SE5 "`searchNotes` is unchanged" (now only for
  `includeLinked` false), D4 agent routing and D4 agentic grounding; its
  "Changed base rules" section lists each change.

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
- Implementation plan: `impl-plans/completed/search-engine-adapter.md` with
  plans P1..P11 and the dispatch manifest
  `impl-plans/active/search-engine-adapter-dispatch.json`. The delta adds
  plans P12-P21 to the same index and manifest. All plans are completed and
  archived under `impl-plans/completed/` with their original file names. The
  dispatch manifest is a workflow runtime artifact and stays in
  `impl-plans/active/`.
- Ontology model used by the delta: `design-docs/specs/kaiba-note.md`
  (D6 provenance, D7 tag classes, D16/D17 tag hierarchy), implemented in
  `Sources/AppCore/NoteStoreSchema.swift` (`tags`, `tag_classes`,
  `note_tags`, `note_links`) and `Sources/AppCore/NoteTagHierarchy.swift`.
- Settings storage reused by D5: `Sources/AppCore/NoteService+AppSettings.swift`
  (`app_settings`, reserved `auth.` prefix) and the administrator check
  `requireStoreAdministrator(in:)` used by `NoteService+APIClients.swift`.

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

`kaiba search-engine <status|sync|reindex>` is an async command. Its parsing
and run logic live in `Sources/AppCore/CommandSearchEngine.swift`, next to
the other `Command*.swift` files, because AppCLI has no test target and
AppCoreTests must cover the command. `Sources/AppCLI/main.swift` only
dispatches it, following the async `"ai"` block. Each subcommand loads the
configuration, builds the adapter through the factory, and calls
`requireStoreAdministrator()`. If no engine is configured, it exits with
code 2 and the message `search engine is not configured`. Every subcommand
accepts the existing CLI output flag `--output json|text`, which defaults to
`text`.

- `status`:
  - Prints `kind`, `indexIdentity`, the health result, the pending outbox
    count, the count of rows with `attempts > 0`, and the oldest due time.
  - Never prints the URL's credentials or any secret.
  - `--output json` gives the same fields as JSON.
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
  likeText`, `min_term_freq: 1`, `min_doc_freq: 1`, `max_query_terms: 25` and
  `minimum_should_match: "10%"`, inside the same filter `bool`. The `cjk`
  analyzer splits a note into many bigrams, so the Elasticsearch default of
  30% hides notes that share only a phrase with the source.
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

---

# Delta: ontology-aware search, hybrid related notes, engine settings

Added 2026-10-04. The sections below extend SE1-SE9; they do not replace
them. Requirement ids D1-D5 match the follow-up request. D0 records what
the base still needs and how its evidence is reported.

## Delta scope and changed base rules

In scope: D0 (finish the base), D1 ontology indexing, D2 ontology search and
facets, D3 hybrid related notes with reasons, D4 the agent `search_notes`
boundary, D5 engine selection and connection settings with hot-swap.

These base rules change:

- The SE1 "Out of scope" entry "the agent `search_notes` tool" is replaced
  by D4.
- Invariant 1 now reads: **No engine selected means unchanged.** An engine
  is selected when the config file has an enabled `searchEngine` section,
  or, when that section is absent, when the store settings (D5) name an
  adapter. With neither, the D5 settings read is the only new behavior. No
  adapter is built, no network call is made, and everything else in
  invariant 1 still holds. The server always installs the D5 runtime
  controller, and its change-event kick is a no-op while no engine is
  attached.
- Invariant 4 is extended. The engine indexes the `note_fts` text fields
  unchanged, plus the ontology fields in D1. Those fields are filter and
  scoring keys, not search text.
- SE8 "Index" changes the index name to `<indexPrefix>-notes-v2` and the
  identity format (D1).

These base rules do not change: the outbox and the drain (SE3), the
two-stage access control (SE4), the `searchNotes` path, error statuses,
pagination limits, and "no total-hit count".

Out of scope for the delta:

- a tag rename, merge or delete API (none exists today);
- engine routing for `AIAgenticSearch` grounding and the `NoteSearchPopup`
  link picker (see D4 and user-qa);
- environment-variable credentials in store settings (the config file keeps
  them);
- non-loopback plain `http`;
- automatic deletion of the old `-v1` index.

## D0. Finishing the base

- **P1, P2, P4, P5, P6, P10** are accepted. The manifest lists them under
  `acceptedDependencies`, and they are not redispatched.
- **P3 and P9** are complete in code. They are re-evidenced, not
  re-implemented. The evidence rules are under "Delta verification".
- **SE6 (P7).** The CLI resolves the engine with the D5 resolver: the
  config file section first, then the store settings. It still requires a
  store administrator. It exits 2 with `search engine is not configured`
  when neither source selects an engine. The CLI never writes settings.
- **SE3 "Who drains" (P8).** The base design is unchanged. D5 adds a
  runtime controller that owns the sync loop, so a loop can be stopped and
  replaced without a restart. P8 may build the loop directly to the D5
  controller shape. Either way, the end state must match D5.
- **P11 integration** covers the base. A final delta-integration plan
  covers D1-D5. That plan runs the full gate set and the extended live
  test.

## D1. Ontology-aware indexing

### Document fields

These fields are added to the adapter-neutral `SearchIndexDocument`. Each
new init parameter defaults to an empty value, so existing call sites and
`FakeSearchEngine` keep compiling.

- `tagApplications: [SearchIndexTagApplication]`: the direct tags, one per
  `note_tags` row. Each entry has `tagId` and `provenance` (`human`, `ai`
  or `system`). Provenance is recorded per application (kaiba-note D6),
  not per tag.
- `pathTags: [SearchIndexPathTag]`: the direct tags plus all of their
  ancestors, following `tags.parent_tag_id`. The traversal is cycle-safe
  and capped at depth 64, matching `validateTagParent`. Each entry has
  `tagId`, `name`, `tagClass: String?` (`tags.class_id`) and
  `isDirect: Bool`. The list is sorted by `tagId` and holds one entry per
  tag. System tags are included, so tag filters keep matching what
  `expandedTagFilterIds` matches today.
- `outgoingLinkNoteIds: [NoteID]` and `incomingLinkNoteIds: [NoteID]`:
  distinct counterparts from `note_links`, across all link kinds. Each list
  is sorted and capped at 500 ids.
- `notebookId` already exists.

`searchIndexDocument(noteId:in:)` (`SearchIndexSynchronizer.swift`) builds
these fields from the store in the same read it already does. The existing
`tagIds`, `tagNames` and `context` fields keep their base derivation.

### Elasticsearch mapping (index `-v2`)

| field | type | source |
| --- | --- | --- |
| `path_tag_ids` | keyword | `pathTags.tagId` |
| `path_tag_names` | keyword | `pathTags.name` (stored for exact inspection, not searched) |
| `tag_classes` | keyword | the distinct non-nil `pathTags.tagClass` values |
| `class_tag_keys` | keyword | `"<classId>:<tagId>"` for each path tag that has a class |
| `tag_provenance_keys` | keyword | `"<provenance>:<tagId>"` for each direct application |
| `outgoing_link_note_ids`, `incoming_link_note_ids` | keyword | the link lists |

All base fields stay as they are, and `dynamic: strict` stays. Keys use tag
ids, not names, so a filter never depends on name normalization.

### Index identity bump

- The index name becomes `<indexPrefix>-notes-v2`.
- `indexIdentity` becomes `elasticsearch:<base>/<indexName>`. `<base>` is
  the normalized base URL: the scheme and host in lowercase, the port when
  present, and the path with no trailing slash. Userinfo is already
  rejected, and the URL holds no secret.
- Pointing at another cluster with the same prefix therefore changes the
  identity and triggers the SE3 backfill.
- An existing store that was activated with the v1 identity backfills
  automatically on the next activation. The v1 index is left in place, as
  in the base rule. The README tells operators how to delete it.

### Write paths that must enqueue

The rule: every statement that changes a D1 field of a note enqueues that
note through the existing outbox, in the same transaction. Enqueueing stays
a no-op before activation (SE3).

| change | write site | enqueue |
| --- | --- | --- |
| tag apply/remove, provenance upgrade, undo/redo of tags | `applyTags`, `removeTag`, `applyNoteTagsDelta` | already covered by `refreshFTS` |
| tag reparent | `defineTag` | already covered by `refreshFTSForNotesUnderTag` (the whole subtree) |
| tag class set or changed | `defineTag` (`class_id` update), `ensureTag` (class set when it was NULL) | new: subtree enqueue, only when the class actually changes |
| tag rename | no API exists | any future rename must call the subtree enqueue |
| link add | `linkNotesInDatabase`, the conversation-turn source links, the inline insert in `promoteCommentToNotebook`, the undo restore in `restoreNoteSnapshot` | new: both endpoints |
| link removal through note deletion | `deleteNoteRows` | new: the surviving counterparts, read before the rows are deleted |
| notebook tag apply/remove (this changes `isLongTermMemory`) | `applyNotebookTags`, `applyNotebookTagIds`, `removeNotebookTag`, `removeNotebookTagById` | new: notebook-scope enqueue |
| notebook library move | `moveNotebook`, tag-memo rehome | already covered |

The new helper is
`enqueueSearchEngineSync(notesUnderTagId:in:)` in
`SearchEngineSyncOutbox.swift`. It is a single set-based statement:

```sql
WITH RECURSIVE subtree(tag_id, depth) AS (... descendants of ?, depth <= 64 ...)
INSERT INTO search_index_outbox (note_id)
SELECT DISTINCT nt.note_id FROM note_tags nt JOIN subtree s ON s.tag_id = nt.tag_id
WHERE EXISTS (SELECT 1 FROM search_engine_sync_state)
ON CONFLICT(note_id) DO UPDATE SET generation = generation + 1,
  attempts = 0, next_attempt_at = NULL, last_error = NULL
```

Fan-out is bounded by the outbox design. There is one row per note,
whatever the subtree size, and the drain pushes 100 notes per pass. A large
subtree costs one indexed insert in the write transaction and no engine
call.

## D2. Ontology-aware engine search

### Protocol additions (adapter-neutral)

All additions default to the base behavior.

- `SearchEngineFilter`:
  - `hierarchyTagIds: [TagID]`, matched any-of. A note matches when its
    path contains any of the ids, so it carries the tag or a descendant.
    The engine evaluates this against the indexed ancestor ids. The
    service no longer expands descendants in SQL for engine search.
  - `tagClassFilters: [SearchEngineTagClassFilter]`. Each entry has
    `tagClass: String` and `tagId: TagID?`. Every entry must match (AND).
    A class alone matches any path tag of that class. A class with a tag
    matches that tag or its descendants, provided the tag has that class.
  - The base `tagIds` field stays (direct tags, any-of). The service stops
    using it for engine search.
- `SearchEngineQuery`:
  - `expansionTagIds: [TagID]`, the ontology expansion (below);
  - `facets: SearchEngineFacetRequest?`, which defaults to nil. The
    request has `tagClassLimit` (10) and `tagLimit` (15).
- `SearchEngineHit` gains `reasons: [SearchEngineHitReason]`, which defaults
  to `[]` (see D3).
- New protocol requirement:
  `searchPage(_ query: SearchEngineQuery) async throws -> SearchEngineSearchPage`.
  The page holds `hits` and `facets: SearchEngineFacets?`.
  - A protocol-extension default calls `search(_:)` and returns
    `facets: nil`, so fakes need no change.
  - `SearchEngineFacets` has `tagClasses` and `tags`. Each is a list of
    `SearchEngineFacetBucket(value: String, count: Int)`. Tag buckets carry
    the tag id as the value.

### Service behavior (`engineSearchNotes`)

New parameters:

- `tagClassFilter: [String] = []`. Each entry is `"<classId>"` or
  `"<classId>:<tagName>"`, split at the first `:`.
- `expandOntology: Bool = true`
- `includeFacets: Bool = false`

The return type becomes `NoteEngineSearchPage`, which holds `hits` and
`facets`. A wrapper keeps the old `[NoteEngineSearchHit]` signature for
existing callers.

Filter resolution reads the store before the engine call:

- `tagFilter` names resolve to tag ids through `resolveTagIds(named:)`,
  without descendant expansion, and become `hierarchyTagIds`. When none
  resolve, the result is empty, as in the base.
- A class filter resolves as follows:
  - an unknown class gives an empty result;
  - a tag name that is unknown, or whose `class_id` differs from the
    class, gives an empty result;
  - more than 10 entries is `invalid_request`.

Ontology expansion is deterministic, with no LLM, and runs only when
`expandOntology` is true:

1. **Normalize** the query and every non-system tag name the same way:
   Unicode lowercase, trim, and collapse runs of whitespace into one space.
2. **Match.** A tag matches when its normalized name has at least 2
   characters and occurs in the normalized query.
   - If the name starts with an ASCII letter or digit, the query character
     before the occurrence must not be one.
   - If the name ends with an ASCII letter or digit, the query character
     after the occurrence must not be one.
   - CJK names therefore match inside unsegmented text, and Latin names
     match only whole words.
3. **Rank.** Keep at most 10 matches: longer names first, then by `tagId`.
4. **Pass on.** The ids become `expansionTagIds`. Tag names are global
   (kaiba-note D7), so matching names reveals nothing about notes. Every
   resulting note still passes the SE4 filter and re-check.

### Elasticsearch query (search)

The base `must` clause becomes a scored `should` with
`minimum_should_match: 1`. With no expansion ids, it scores exactly like
the base query.

| clause (`_name`) | query | boost |
| --- | --- | --- |
| `text-match` | the base `multi_match` (`title^3, body, tags^2, context`) | 1.0 (BM25) |
| `tag-match` | `constant_score` over `terms tag_ids: expansionTagIds` | 4.0 |
| `tag-hierarchy-match` | `constant_score` over `terms path_tag_ids: expansionTagIds` | 2.0 |

- A note tagged directly with a matched tag scores 6.0 from the ontology
  clauses, because the tag is also on its path. A note tagged with a
  descendant scores 2.0. A note that only matches text gets BM25 alone.
- A note that carries the tag matches even when its body lacks the term.
  Such a note has no highlight, so the snippet falls back to
  `snippet(from:query:)`.
- New `filter` clauses:
  - `terms path_tag_ids: hierarchyTagIds`;
  - per class filter, `term tag_classes: <class>`, or
    `term class_tag_keys: "<class>:<tagId>"` when a tag is given.
- `must_not` is unchanged. The highlight, `from`, `size` and
  `_source: [note_id]` are unchanged.
- **Facets**, only when requested, run in the same request:
  - `aggs.tag_classes`: `terms` on `tag_classes`, size `tagClassLimit`;
  - `aggs.tags`: `terms` on `tag_ids` (direct tags, so root folders do not
    dominate), size `tagLimit`.
- `matched_queries` become `SearchEngineHitReason`s (`text-match`,
  `tag-match`, `tag-hierarchy-match`).

### Facet access rule

Facet counts come from the engine under the same engine filter: library,
owner, notebook, long-term memory and the ontology filters. They never
count documents outside the libraries the caller reaches.

They can include notes that the store re-check would drop:

- a note in a reachable library that is still pending ingest;
- a note whose index entry lags a write by at most one drain.

The design accepts this bounded imprecision. Buckets are presented as
refinement hints, not totals.

The service resolves tag buckets to `{tagId, name, tagClass, count}` and
drops buckets for unknown tags and for system tags.

### GraphQL and KaibaClient

```graphql
engineSearchNotes(query: String!, notebookId: String, tagFilter: [String!], tagClassFilter: [String!], expandOntology: Boolean, facets: Boolean, limit: Int, offset: Int): EngineNoteSearchQueryPayload!
type EngineNoteHit { note: Note!, snippet: String!, score: Float!, reasons: [EngineHitReason!]! }
type EngineHitReason { kind: String!, tags: [String!]! }
type EngineSearchFacets { tagClasses: [EngineFacetBucket!]!, tags: [EngineTagFacetBucket!]! }
type EngineFacetBucket { value: String!, count: Int! }
type EngineTagFacetBucket { tagId: String!, name: String!, tagClass: String, count: Int! }
type EngineNoteSearchQueryPayload { result: ControlPlaneResult!, value: [EngineNoteHit!], facets: EngineSearchFacets }
```

- The changes are additive. `expandOntology` defaults to true, and
  `facets` defaults to false. `relatedNotes` returns `facets: null`.
- The schema inventory, authorization tests and KaibaClient contract tests
  are updated.
- KaibaClient `engineSearchNotes(...)` gains defaulted parameters
  `tagClassFilter`, `expandOntology` and `facets`. A page model carries the
  hits and facets.

### Web search UI (`SearchView`)

This applies only when `searchEngineEnabled` is true and the method is
`grep`.

- **Facets.** The first page is requested with `facets: true`. Under the
  status line, refinement chips show the classes and top tags, each with
  its count.
- **Filters.** Clicking a tag chip adds the tag to `tagFilter`, and
  clicking a class chip adds the class to `tagClassFilter`. Active filters
  show as removable chips. Every change re-runs the query and discards
  stale responses with the existing generation counter.
- **Fallback.** On `search-engine-unavailable` or `feature-disabled`, the
  view falls back to `searchNotes` as in SE7. Tag filters carry over,
  because FTS supports `tagFilter`. Class filters are cleared.
- `NoteSearchPopup` is unchanged.

## D3. Hybrid related notes with reasons

### Signals

The service reads the signals from the store while it loads the source note
(`requireNote`, unchanged). They never depend on the source's own index
entry.

- `S`: the source's direct non-system tags.
- `P`: the parents of `S`, excluding system tags.
- `A`: all ancestors of `S`, excluding `S` and system tags.
- `E`: the pairs `(class, tagId)` for tags in `S` whose class is `person`
  or `event`. These are the entity classes. Year, topic, folder and
  document-kind tags still count through `S`.

Each list is capped at 50 entries.

`SearchEngineRelatedQuery` gains
`signals: SearchEngineRelatedSignals?`, which defaults to nil (the base
behavior). It holds `sourceNoteId`, `sharedTagIds` (S), `nearTagIds`
(S union P), `ancestorTagIds` (A) and `entityTags` (E).

### Elasticsearch query (related)

The query is a `bool` with `minimum_should_match: 1` and the base `filter`
and `must_not`. The source note stays excluded through `excludedNoteIds`.

| clause (`_name`) | query | boost |
| --- | --- | --- |
| `text-similarity` | the base `more_like_this` (omitted when `likeText` is blank) | 1.0 |
| `shared-tag` | `constant_score` over `terms tag_ids: S` | 3.0 |
| `related-tag` | `constant_score` over `bool.should[terms path_tag_ids: S union P, terms tag_ids: A]` | 1.5 |
| `shared-entity` | `constant_score` over `terms class_tag_keys: E as "<class>:<tagId>"` | 2.0 |
| `linked` | `constant_score` over `bool.should[term outgoing_link_note_ids: source, term incoming_link_note_ids: source]` | 5.0 |

The ordering follows from these boosts:

- An explicit link is the strongest signal.
- The same tag (3.0, plus 1.5 because the tag is on the candidate's path)
  outranks a sibling, parent, child or ancestor tag (1.5).
- A shared person or event tag adds 2.0 on top of `shared-tag`.
- Text similarity adds its BM25-scaled score.

The boosts are constants inside the adapter. The protocol carries only the
signals. Sibling matching goes through the parent's id in `path_tag_ids`.

### Reasons

- The adapter maps each hit's `matched_queries` to reason kinds:
  `text-similarity`, `shared-tag`, `related-tag`, `shared-entity` and
  `linked`.
- After the SE4 re-check, the service enriches the final page from the
  store:
  - A `shared-tag` or `shared-entity` reason gets the names of the
    candidate's direct non-system tags that are in `S`, at most 5,
    sorted.
  - When the store intersection is empty because the index is stale, the
    reason is dropped. The hit itself stays.
- GraphQL exposes reasons as `EngineHitReason { kind, tags }`.
- `relatedNotes` keeps its arguments, limits and statuses.

### Web (`RelatedNotesSection`)

Each related note shows a one-line reason summary under its title. The
items are joined with ` · ` in this fixed order:

- `Linked`
- `Shared tags: a, b`
- `Same person/event: x`
- `Related tags`
- `Similar text`

The summary is plain text, never HTML, and is omitted when there are no
reasons. Tests cover the rendering and the ordering.

## D4. Agent and agentic-search boundary

- **User-facing search never calls an LLM.** `engineSearchNotes`,
  `relatedNotes`, the expansion, the facets and the reasons run only store
  SQL and engine requests. The files that implement them,
  `NoteService+SearchEngine*.swift`, `SearchEngine*.swift` and
  `Elasticsearch*.swift`, reference no AI provider, agent-gateway or
  `AIAgenticSearch` type. A test runs these paths on a store with no AI
  configuration. A verification grep confirms the boundary.
- **The agent `search_notes` tool** (`KaibaAgentToolbox`) routes through the
  engine when all three of these hold:
  - an engine is attached;
  - `include_linked` is false. The graph-neighbor expansion stays FTS-only;
  - the engine call does not throw.

  Otherwise it runs the current FTS path unchanged. Details:
  - `KaibaAgentToolbox.execute` is already async. `search_notes` gets an
    async branch, and the other tools keep the synchronous `run`.
  - The engine call is
    `engineSearchNotes(query:notebookId:tagFilter:limit:offset: 0)`, with
    expansion on and no facets.
  - The output keeps every existing key.
    - `term_coverage` is computed with the term split of
      `NoteSearchLexicalFusion`: the share of query terms found
      case-insensitively in the title plus the retrieval text.
    - `is_linked_neighbor` is false.
    - One key is added: `"retrieval": "search-engine"` or
      `"retrieval": "full-text"`.
  - The tool schema text is unchanged.
- **`AIAgenticSearch` grounding stays on FTS.** It fuses per-term FTS ranks
  with comment search through `reciprocalRankFusion`. Agents still reach
  the engine through `search_notes`. Engine grounding for it is an open
  question in user-qa.

## D5. Engine selection and connection settings

### Sources and precedence

The resolver (`SearchEngineSettingsResolver`, AppCore) returns one of:

- `.managedByConfig(KaibaSearchEngineConfiguration)`. The config file has a
  `searchEngine` section, whether it is enabled or not. The section wins.
  Store settings are ignored, the settings UI is read-only, and every
  settings mutation is rejected with status `settings-managed-by-config`.
- `.store(SearchEngineConnectionSettings, secret)`. There is no config
  section, and the store settings name an adapter.
- `.none`. There is no config section, and the store settings are absent or
  `kind: "none"`.

The server at start, the D5 reload and the CLI (D0) all use the same
resolver. A config-section error stays fatal, as in SE2. A stored setting
that fails to build at server start is not fatal: the server logs
`kaiba search-engine: stored settings invalid: <field>`, runs FTS-only,
and lets the administrator fix the settings in the UI.

### Store format

Both keys sit under the existing reserved `auth.` prefix. The generic
`appSetting` and `setAppSetting`, which have no admin gate, can therefore
neither read nor write them, and they answer with the existing
"invalid key" error.

- `auth.search-engine.settings` holds the non-secret fields:
  `{kind, url, indexPrefix, authMode, username, verifyTLS, requestTimeoutSeconds}`.
- `auth.search-engine.secret` holds `{authMode, target, secret}`. The
  secret is either the Basic password or the API key. It is bound to the
  auth mode and the connection target it was entered for. `target` is the
  normalized base URL defined in D1 "Index identity bump": the scheme and
  host in lowercase, the port when present, and the path with no trailing
  slash. Without this binding, a stored secret could be sent to a new host
  without anyone re-entering it.

Both are written in one transaction. The secret is stored in the note
store as the JWT signing secret is, protected by the store's file
permissions, and it replicates with the store under the Turso driver. It
never appears in the config file, logs, errors, GraphQL reads or the web
client's storage.

### Normalized connection settings and factory

`SearchEngineConnectionSettings` has these fields:

- `kind`
- `url`
- `indexPrefix` (default `kaiba`)
- `authMode`: `none`, `basic` or `apiKey`
- `username` (required for basic)
- `verifyTLS` (default true)
- `requestTimeoutSeconds` (`1...120`, default 10)

Behavior:

- `SearchEngineFactory.make(settings:secret:)` builds the adapter.
- The base `make(configuration:environment:)` maps the config section onto
  the same settings, with environment-resolved credentials, `verifyTLS`
  true and a 10-second timeout, and calls it.
- Validation repeats SE2: the kind is registered, the URL is `http` or
  `https`, there is no userinfo, plain `http` is allowed only on loopback,
  and the prefix matches the SE2 regex.
- It adds these limits:
  - `url` up to 2048 characters;
  - `username` 1-256 characters;
  - `secret` 1-4096 characters;
  - no control characters in any field;
  - `verifyTLS: false` only with `https`.
- Errors name the field only, for example `searchEngine.url`.
- **Timeouts.** Queries, health checks and `ensureIndex` use
  `requestTimeoutSeconds`. Bulk uses `max(30, requestTimeoutSeconds)`.
- **`verifyTLS: false`.** The adapter's URLSession delegate accepts the
  server certificate for that host only. This needs the Security
  framework. Where it is unavailable, validation rejects the setting with
  `searchEngine.verifyTLS`. The web form shows a warning next to the
  option.
- **Adapter registry.** `SearchEngineFactory.adapters` is a static list of
  `SearchEngineAdapterDescriptor(kind, displayName, authModes)`. Today the
  list is only Elasticsearch, with `none`, `basic` and `apiKey`. Both the
  GraphQL settings read and kind validation use the list, so a new adapter
  shows up in the picker by appending a descriptor.

### AppCore API (`NoteService+SearchEngineSettings.swift`)

Every method calls `requireStoreAdministrator(in:)` first, the same gate as
`NoteService+APIClients.swift`. A non-admin gets the existing not-found
shaped error.

- **`searchEngineSettings()`** returns a `SearchEngineSettingsView`:
  - `managedBy`: `config`, `store` or `default`;
  - `kind` (`none` when disabled);
  - `url`, `indexPrefix`, `authMode`, `username`, `verifyTLS`,
    `requestTimeoutSeconds`;
  - `hasSecret`;
  - `adapters`;
  - `active`, which is whether an engine is attached now.

  For `config`, the fields come from the section, and `username` is null,
  because config credentials are environment-variable names.
  `hasSecret` is true when a credential is configured. No secret, and no
  partial or masked secret, is ever returned.
- **`updateSearchEngineSettings(_ input:)`**:
  1. Rejects the update when the settings are managed by config.
  2. Validates the input by building the adapter. Nothing is persisted on
     failure.
  3. Persists the settings.
  4. Calls `searchEngineSlot.reload()` and returns the refreshed view.

  Secret rules:
  - `kind: "none"` stores `{kind: "none"}` and deletes the secret.
  - An omitted `secret` keeps the stored one only if both of these hold:
    - the stored `authMode` equals the new `authMode`;
    - the stored `target` equals the new normalized `url`.

    Otherwise the update fails with `invalid-settings` and field
    `searchEngine.secret`, and nothing is persisted. A password is
    therefore never reused as an API key, and a stored secret is never
    sent to a URL it was not entered for.
  - A newly entered secret is stored with the new `authMode` and `target`.
  - `clearSecret: true` together with an auth mode other than `none` is
    invalid.
  - `authMode: none` deletes the secret.
- **`testSearchEngineConnection(_ input:)`** builds an adapter from the
  unsaved input. It reuses the stored secret under the same rule as
  update: both the `authMode` and the normalized target must be unchanged.
  On a mismatch with an omitted secret, it returns status
  `invalid-settings` with detail `searchEngine.secret` and makes no
  network call. Otherwise it calls only `health()`, with a timeout of
  `min(requestTimeoutSeconds, 10)`. It persists nothing and never calls
  `ensureIndex`. The result has these fields:
  - `available`;
  - `status`, one of `available`, `unhealthy`, `unavailable`, `rejected`,
    `invalid-response` or `invalid-settings`;
  - `detail`, which is the cluster status word, the field name, or the
    adapter's already-sanitized error text.

  Before the detail is returned, the service replaces the secret and the
  username with `[redacted]` and truncates the text to 200 characters. The
  detail never includes the URL or any headers. It is rejected when the
  settings are managed by config.

### Hot-swap

- **Shared slot.** `SearchEngineSlot` (AppCore) is a `final class`,
  `Sendable` and lock-protected. It holds the current
  `(any SearchEngine)?` and an optional reload handler.
  - `NoteService` gains `public let searchEngineSlot`, which defaults to a
    fresh slot in `init`.
  - The base `searchEngine` property becomes a computed get and a
    nonmutating set over the slot. The P5 API and its tests are unchanged.
  - Scoped copies, such as `scoped(to:)` and the per-request GraphQL
    scoping, share the slot by reference. Every `NoteService` the server
    builds, including the auto-action dispatcher's, receives the runtime's
    slot.
- **Controller.** `SearchEngineRuntimeController` (AppServer) is an actor
  that owns the slot's engine and the SE3 sync loop.
  - At start it resolves the settings, attaches the engine, starts the loop
    (P8 semantics), and installs itself as the slot's reload handler.
  - `reload()` runs serialized:
    1. Re-resolve the settings. When they are managed by config, the reload
       is a no-op.
    2. Build the new adapter.
    3. Stop the current loop, awaiting it.
    4. Replace the slot's engine.
    5. Start a new loop when the new engine is non-nil.
  - The new loop's `ensureIndex` and `activateSearchEngineSync` run first.
    A changed `indexIdentity`, from a new cluster, prefix or version,
    therefore triggers the durable SE3 backfill. The swap never waits on
    the engine.
  - **Concurrency.** An in-flight query has already captured the old
    adapter, so it finishes against it, and its hits still pass the store
    re-check.
  - **Stopping mid-drain.** A drain that is cancelled while stopping
    settles as a failure and retries with backoff. If even that settle is
    lost, the 60-second claim lease returns the rows. No outbox row is
    lost.
  - **Concurrent updates.** They serialize in the actor. Each reload reads
    the latest stored settings, so the result converges on the last write.
  - The kick observer is always installed. It forwards to the current loop
    and does nothing when there is none.
- **Disable.** Choosing `none` detaches the engine and stops the loop.
  - `searchEngineCapability.enabled` reads the slot on every call, so it
    turns false at once.
  - Engine fields answer `feature-disabled`. The base outbox rule for a
    disabled engine applies.
  - The web client treats `feature-disabled` from an engine field as
    `searchEngineEnabled = false` and hides the engine surfaces.

### GraphQL

```graphql
# type Query
searchEngineSettings: SearchEngineSettingsPayload!
# type Mutation
updateSearchEngineSettings(input: SearchEngineSettingsInput!): SearchEngineSettingsPayload!
testSearchEngineConnection(input: SearchEngineSettingsInput!): SearchEngineConnectionTestPayload!

type SearchEngineAdapterDescriptor { kind: String!, displayName: String!, authModes: [String!]! }
type SearchEngineSettings { managedBy: String!, kind: String!, url: String, indexPrefix: String, authMode: String!, username: String, hasSecret: Boolean!, verifyTLS: Boolean!, requestTimeoutSeconds: Int!, adapters: [SearchEngineAdapterDescriptor!]!, active: Boolean! }
type SearchEngineSettingsPayload { result: ControlPlaneResult!, value: SearchEngineSettings }
input SearchEngineSettingsInput { kind: String!, url: String, indexPrefix: String, authMode: String, username: String, secret: String, clearSecret: Boolean, verifyTLS: Boolean, requestTimeoutSeconds: Int }
type SearchEngineConnectionTestResult { available: Boolean!, status: String!, detail: String! }
type SearchEngineConnectionTestPayload { result: ControlPlaneResult!, value: SearchEngineConnectionTestResult }
```

Statuses:

- A non-admin gets the existing not-found mapping of the admin gate.
- Config-managed settings give `settings-managed-by-config`.
- Validation failures give `invalid-settings`, with the field name as the
  only diagnostic.
- A connection test that fails still has `accepted: true`. The outcome is
  in `value.status`.

The new fields are registered in the same lists as SE5 and are covered by
the inventory and authorization tests. A test asserts that no settings
response, error or diagnostic contains a test secret value. KaibaClient
adds `searchEngineSettings()`, `updateSearchEngineSettings(_:)` and
`testSearchEngineConnection(_:)`.

### Web settings section

`web/src/components/SearchEngineSettings.tsx` renders in `ConfigView` after
`UserAgentSettings`. Its validation is a pure function in
`web/src/notes/searchEngineSettings.ts`.

- **Visibility.** The section loads `searchEngineSettings` on mount. It
  renders nothing when the result is not accepted, which covers non-admins
  and older servers.
- **Config-managed.** When `managedBy` is `config`, the section shows the
  values read-only, with the note `Managed by the server configuration
  file`, and no buttons.
- **Fields.**
  - an engine select: `None` plus `adapters`;
  - URL;
  - index prefix;
  - an auth-mode select, limited to the adapter's `authModes`;
  - username, shown for basic;
  - the secret: `type="password"`, `autocomplete="new-password"`. While
    the URL and auth mode match the loaded values and `hasSecret` is set,
    the placeholder reads `Stored`, and blank means keep the stored secret.
    If the normalized URL or the auth mode differs from the loaded value
    and the new auth mode is not `none`, the secret is required. The
    `Stored` placeholder is then removed, and both Save and Test
    connection are blocked until a secret is entered. This mirrors the
    server's target and auth-mode binding;
  - `Clear stored secret`;
  - `Verify TLS certificates`, enabled only for `https`, with a warning
    when unchecked;
  - request timeout.
- **Client validation** mirrors the server rules. The server stays
  authoritative.
- **Buttons.** `Test connection` shows the status and the sanitized
  detail. `Save` persists the settings, then clears the secret input,
  reloads the view and reloads `searchEngineCapability` in the app store.
- **Secret handling.** The secret is never written to the `web` app
  setting, `localStorage` or `sessionStorage`, and never logged. It does
  not interact with the server-credential (bearer, origin) rules.
- **Tests.**
  - `SearchEngineSettings.integration.tsx` covers:
    - hidden for non-admins;
    - read-only when managed by config;
    - validation errors;
    - test-connection rendering;
    - save followed by a capability reload;
    - the secret absent from storage after save;
    - changing the URL while `hasSecret` is set requires re-entering the
      secret before Save or Test connection is sent.
  - `searchEngineSettings.test.ts` covers the validation rules.
  - The existing `serverEndpoint`/`client` credential tests must keep
    passing unchanged.

## Delta test plan

- **AppCore, `SearchEngineOntologyIndexTests`.**
  - The document builder fills the D1 fields: ancestors, classes,
    provenance and links in both directions.
  - Every write path in the D1 table enqueues the right ids after
    activation, including a class change on a subtree and a link added
    from each insert site.
  - Note deletion enqueues the surviving link counterparts.
  - Notebook tag changes enqueue the notebook.
  - The identity includes the normalized base URL and `-v2`, and a v1
    activation backfills.
- **AppCore, `SearchEngineOntologyQueryTests`** (fake engine):
  - filter resolution: hierarchy ids without SQL expansion, class filters,
    unknown names giving an empty result, more than 10 class filters being
    rejected;
  - expansion matching: CJK substrings, Latin word boundaries, the
    10-match cap, system tags excluded;
  - facet hydration;
  - related signals S, P, A and E;
  - reason enrichment, and dropping stale reasons;
  - the source note never returned;
  - the store re-check still applied.
- **AppCore, `ElasticsearchSearchEngineTests`** (mock transport): exact
  request bodies for the D2 search with filters, expansion and
  aggregations, and for the D3 related query. Also the mapping of
  `matched_queries` to reasons, and of aggregations to facets.
- **AppCore, `SearchEngineSettingsTests`:**
  - admin gate;
  - config precedence and lock;
  - validation per field;
  - the secret-retention rules;
  - a stored secret is bound to its target. With a stored
    `{authMode: basic, target: https://es.internal:9200}`, an input that
    changes the `url` to another host and omits the secret is rejected with
    `invalid-settings` and `searchEngine.secret`. This holds for both
    `updateSearchEngineSettings` (nothing persisted) and
    `testSearchEngineConnection`. The test uses an injected recording
    transport and asserts that it received no request. The same applies to
    an `authMode` change with an omitted secret. An unchanged target and
    auth mode reuse the stored secret;
  - `kind none` deletes the secret;
  - `appSetting`/`setAppSetting` refuse both `auth.search-engine.*` keys;
  - test-connection sanitizing, using a transport that echoes the secret
    in its error;
  - the reload handler is called.
- **AppCore, `AgentSearchNotesRoutingTests`:**
  - the engine is used when attached;
  - FTS is used when detached, with `include_linked`, and after an engine
    error;
  - the output keys are unchanged and `retrieval` is added.
- **AppServer, `SearchEngineRuntimeControllerTests`** (fake engines):
  - start with config, with store settings, and with neither;
  - an invalid stored setting is not fatal;
  - reload swaps the adapter seen by a scoped service copy;
  - an identity change backfills;
  - disable makes the capability false and stops the loop;
  - concurrent reloads converge;
  - a config-managed store ignores reload.
- **AppGraphQL:** the new fields, admin gating, statuses, facets and
  reasons in payloads, and no secret in any response.
- **KaibaClient:** typed operations against the contract.
- **Web:** the `SearchView` facet chips and filters, `RelatedNotesSection`
  reasons, and the `SearchEngineSettings` tests listed in D5.
- **Live (`ElasticsearchLiveTests`, gated by `KAIBA_ELASTICSEARCH_URL`):**
  - the existing round trip on `-v2`;
  - ontology search: a descendant-tag filter, a class filter, a tag-only
    match via expansion ranked above a text-only match, and facets
    returned;
  - related notes: a linked note, then a shared-tag note, then a text-only
    note, each with the expected reason kinds;
  - settings hot-swap at the service level: store settings with prefix A,
    then a reload to prefix B. The identity changes, the backfill drains
    into B, search on B finds the notes, and disabling yields
    `notConfigured`.

  The test deletes every index it created.

## Delta verification

Gate-compatible evidence: each behavioral record is a test-runner command
(`swift test`, `bun test`, `vitest run`, or `mise run <task containing
test>`) with exitCode 0. Every count it records (testsRun, testsPassed,
testCount) must be greater than 0. Each record keeps its complete log path
and final exit status.

- `mise run build`
- `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig mise exec -- swift test`
- `mise run lint`
- `mise run web:check`, plus separate records for
  `cd web && mise exec -- bun test src` (bun count > 0) and
  `cd web && mise exec -- bunx vitest run` (vitest count > 0). These are the
  two halves of the web `test` script (`bun test src && vitest run`).
- `mise run tauri:check`. It needs macOS and runs locally only.
- `mise run search:up`, then
  `KAIBA_ELASTICSEARCH_URL=http://127.0.0.1:9200 mise run search:test-live`.
  - Record only the XCTest count, for example `Executed N tests, 0
    failures` with N > 0. The swift-testing line of this filtered run
    reports 0 tests and is not a count record.
  - The env-gated skip, where the test skips when `KAIBA_ELASTICSEARCH_URL`
    is unset, is a non-behavioral note, never a verification record.
  - The P3 plan's verification list is amended the same way.
- Boundary grep, expected to return nothing:
  `grep -nE "AIAgenticSearch|AgentInvok|AgentGateway|AgentReply|ClaudeSubscription" Sources/AppCore/NoteService+SearchEngine*.swift Sources/AppCore/SearchEngine*.swift Sources/AppCore/Elasticsearch*.swift`
- `wc -l` on every touched Swift file: each is under 1000 lines.

## Delta rollout

- **Existing stores with an engine.** The first start after upgrade
  computes the `-v2` identity, creates the new index and backfills through
  the outbox. Note writes are never blocked. The old `-v1` index stays
  until an operator deletes it.
- **Existing config-file deployments** become `managedBy: config`. Their
  behavior is unchanged apart from the `-v2` backfill, and the settings UI
  is read-only for them.
- **New deployments without a config section** can turn the engine on from
  the web settings. No restart is needed.
- **Store schema.** No new tables or columns. Settings use the existing
  `app_settings` table, and the outbox tables are unchanged. The store
  version stays at 23.

## Plan partition guidance (for the plan author)

These are boundaries, not binding plan ids:

- **D1:** document fields, mapping, identity and write-path enqueues.
- **D2:** protocol, ES query and facets, service, GraphQL and client.
- **D3:** related signals, query, reasons, GraphQL and client.
- **D4:** agent tool routing.
- **D5 core:** resolver, factory settings, slot, AppCore API, GraphQL and
  client.
- **D5 server:** the runtime controller, plus the P8 wiring.
- **Web:** search facets, related reasons and the settings section.
- **Delta integration.**

Shared hot files need one owner per wave: `SearchEngine.swift`,
`ElasticsearchRequestBodies.swift`, `NoteService+SearchEngine.swift`,
`NoteGraphQLService+SearchEngine.swift`, the GraphQL schema and field
lists, and `KaibaServerRuntime.swift`. D2 and D3 both touch the
adapter-neutral types and the ES request bodies. Either serialize them or
give the type additions to D1.
