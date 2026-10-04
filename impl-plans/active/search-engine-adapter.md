# Search Engine Adapter (index)

**Status**: In Progress
**Design Reference**: `design-docs/specs/search-engine-adapter.md` (SE1-SE9), `design-docs/user-qa/search-engine-adapter.md`
**Dispatch manifest**: `impl-plans/active/search-engine-adapter-dispatch.json`

## Purpose

Add an optional external search engine to kaiba. When a `searchEngine`
section is configured, notes sync through an AppCore `SearchEngine` protocol
to an Elasticsearch 8.x adapter. The engine serves full-text search and
related notes through GraphQL, KaibaClient, the CLI and the web client,
behind a capability flag. Access is enforced in the engine query and
re-checked in the store. Without the section, kaiba behaves exactly as today.

## Binding invariants (from the design)

1. **Unconfigured means unchanged.**
   - No adapter is built and no network call is made.
   - `searchNotes` and every `NoteSearch*.swift` path behave as today.
   - `searchEngineCapability.enabled` is false.
   - The web client hides every engine surface.
2. **Writes never depend on the engine.** No engine call runs inside a
   store transaction. A note write only touches the local outbox table, in
   the same transaction as the note change.
3. **The store is the authority on access.** Every engine hit passes a store
   re-check that uses the same predicates as `searchNotes`.
4. **The engine indexes what `note_fts` indexes,** with the same text
   derivation.
5. **Callers use only `any SearchEngine`.** Elasticsearch types, JSON and URLs
   stay in `Sources/AppCore/Elasticsearch*.swift`.

## Plans and waves

| planId | plan file | wave | dependsOn |
| --- | --- | --- | --- |
| P1-core-contract | `impl-plans/active/search-engine-adapter-p1-core-contract.md` | 1 | - |
| P2-store-outbox | `impl-plans/active/search-engine-adapter-p2-store-outbox.md` | 1 | - |
| P9-web-client | `impl-plans/active/search-engine-adapter-p9-web-client.md` | 1 | - |
| P10-local-tooling | `impl-plans/active/search-engine-adapter-p10-local-tooling.md` | 1 | - |
| P3-elasticsearch-adapter | `impl-plans/active/search-engine-adapter-p3-elasticsearch-adapter.md` | 2 | P1 |
| P4-sync-drain | `impl-plans/active/search-engine-adapter-p4-sync-drain.md` | 2 | P1, P2 |
| P5-engine-query-service | `impl-plans/active/search-engine-adapter-p5-engine-query-service.md` | 2 | P1, P2 |
| P6-graphql-client | `impl-plans/active/search-engine-adapter-p6-graphql-client.md` | 3 | P1, P5 |
| P7-cli | `impl-plans/active/search-engine-adapter-p7-cli.md` | 3 | P2, P3, P4 |
| P8-server-sync-loop | `impl-plans/active/search-engine-adapter-p8-server-sync-loop.md` | 3 | P2, P3, P4, P5 |
| P11-integration | `impl-plans/active/search-engine-adapter-p11-integration.md` | 4 | all of the above |

How the dependencies were chosen:

- `Sources/AppCore/NoteService.swift` has one owner per wave. P2 adds the
  outbox enqueue line in wave 1, and P5 adds the `searchEngine` stored
  property in wave 2. That is why P5 depends on P2.
- P9 (web) builds against the GraphQL shapes pinned below, and its tests use
  mocks, so it runs in wave 1.
- P10 (compose file and mise tasks) is independent of the Swift code.

## Pinned cross-plan contracts

Every plan treats these as fixed. If a plan needs a change, it stops and
records the conflict in its Progress Log. It never edits another plan's
file.

### AppCore protocol and types (P1, `Sources/AppCore/SearchEngine.swift`)

```swift
public protocol SearchEngine: Sendable {
  var indexIdentity: String { get }
  func health() async throws -> SearchEngineHealth
  func ensureIndex() async throws
  func apply(_ operations: [SearchIndexOperation]) async throws -> [SearchIndexOperationResult]
  func search(_ query: SearchEngineQuery) async throws -> [SearchEngineHit]
  func relatedNotes(_ query: SearchEngineRelatedQuery) async throws -> [SearchEngineHit]
}
```

- **Value types.** All are `public`, `Equatable` and `Sendable`, with public
  memberwise-style inits:
  - `SearchIndexDocument`: `noteId`, `notebookId`, `libraryId`,
    `ownerUserId`, `title`, `body`, `tagIds: [TagID]`,
    `tagNames: [String]`, `context`, `isLongTermMemory: Bool`, `createdAt`,
    `updatedAt`. The two timestamps are store timestamp strings.
  - `SearchIndexOperation`: `.upsert(SearchIndexDocument)` or
    `.delete(NoteID)`. It has a computed `noteId`.
  - `SearchIndexOperationResult`: `noteId` and
    `outcome: SearchIndexOperationOutcome`.
  - `SearchIndexOperationOutcome`: `.succeeded` or `.failed(String)`.
  - `SearchEngineFilter`: `libraryIds: [LibraryID]?`,
    `ownerUserId: UserID?`, `notebookId: NotebookID?`, `tagIds: [TagID]`,
    `excludesLongTermMemory: Bool`, `excludedNoteIds: [NoteID]`.
  - `SearchEngineQuery`: `text`, `filter`, `from: Int`, `size: Int`.
  - `SearchEngineRelatedQuery`: `likeText`, `filter`, `size: Int`.
  - `SearchEngineHit`: `noteId`, `score: Double`, `highlight: String?`.
  - `SearchEngineHealth`: `isAvailable: Bool`, `detail: String`.
  - `NoteEngineSearchHit`: `note: Note`, `snippet: String`,
    `score: Double`.
- **`SearchEngineError`.** It is `Error`, `Equatable`, `Sendable` and
  `CustomStringConvertible`, with these cases:
  - `.notConfigured`
  - `.unavailable(String)`
  - `.rejected(status: Int, reason: String)`
  - `.invalidResponse(String)`

  Its description never contains headers, credentials or URL userinfo.
- **Protocol extension.** `upsert(_ document:) async throws ->
  SearchIndexOperationResult` and `delete(noteId:) async throws ->
  SearchIndexOperationResult` both call `apply` with one operation.
- **Configuration.** `KaibaConfiguration.searchEngine:
  KaibaSearchEngineConfiguration?` is stored under the JSON key
  `searchEngine`. The struct is flat, with these fields:
  - `kind: String`
  - `enabled: Bool?`
  - `url: String`
  - `indexPrefix: String?`
  - `apiKeyEnvironmentVariable: String?`
  - `usernameEnvironmentVariable: String?`
  - `passwordEnvironmentVariable: String?`

  It has a computed `isEnabled` (`enabled ?? true`) and a computed
  `resolvedIndexPrefix` (`indexPrefix ?? "kaiba"`).

### Store outbox (P2, `Sources/AppCore/SearchEngineSyncOutbox.swift`)

Internal free functions, used inside an existing write transaction:

- `enqueueSearchEngineSync(noteIds: [NoteID], in database: SQLiteDatabase) throws`
- `enqueueSearchEngineSync(notebookId: NotebookID, in database: SQLiteDatabase) throws`

Public types:

- `SearchIndexOutboxRow`: `noteId: NoteID`, `generation: Int64`,
  `attempts: Int`.
- `SearchIndexOutboxFailure`: `row: SearchIndexOutboxRow`,
  `message: String`.
- `SearchIndexOutboxStatus`: `isActivated: Bool`, `indexIdentity: String?`,
  `pending: Int`, `failing: Int`, `due: Int`, `nextDueAt: String?`.

`public extension NoteService`:

- `@discardableResult func activateSearchEngineSync(indexIdentity: String) throws -> Bool`.
  Returns true when it enqueued a backfill.
- `@discardableResult func enqueueAllNotesForSearchEngineSync() throws -> Int`
- `func claimSearchIndexOutbox(limit: Int, claimToken: String, now: Date, leaseSeconds: TimeInterval = 60) throws -> [SearchIndexOutboxRow]`
- `func settleSearchIndexOutbox(succeeded: [SearchIndexOutboxRow], failed: [SearchIndexOutboxFailure], claimToken: String, now: Date) throws`
- `func searchIndexOutboxStatus(now: Date = Date()) throws -> SearchIndexOutboxStatus`

### Sync drain (P4, `Sources/AppCore/SearchIndexSynchronizer.swift`)

- `public struct SearchIndexDrainReport`: `pushed`, `failed`, `remaining`,
  `remainingDue`, all `Int`. It is Equatable and Sendable.
- `public struct SearchIndexSynchronizer: Sendable`:
  - `init(service: NoteService, now: @escaping @Sendable () -> Date = { Date() })`
  - `func drainOnce(engine: any SearchEngine, batchSize: Int = 100) async throws -> SearchIndexDrainReport`
  - `func drainUntilIdle(engine: any SearchEngine, batchSize: Int = 100) async throws -> SearchIndexDrainReport`
- Internal `func searchIndexDocument(noteId: NoteID, in database: SQLiteDatabase) throws -> SearchIndexDocument?`.
  Returns nil when the note does not exist.

### Engine query service (P5)

- `NoteService` gains the stored property
  `public var searchEngine: (any SearchEngine)? = nil`, in
  `Sources/AppCore/NoteService.swift`.
- `public extension NoteService`, in
  `Sources/AppCore/NoteService+SearchEngine.swift`:
  - `var isSearchEngineEnabled: Bool`
  - `func engineSearchNotes(query: String, notebookId: NotebookID? = nil, tagFilter: [String] = [], limit: Int = 20, offset: Int = 0) async throws -> [NoteEngineSearchHit]`
  - `func relatedNotes(noteId: NoteID, limit: Int = 8) async throws -> [NoteEngineSearchHit]`
- Error contract:
  - no engine: `SearchEngineError.notConfigured`
  - an empty or whitespace-only query: `NoteServiceError.invalidInput`
  - an unreachable source note: `NoteServiceError.notFound`
  - engine failures are rethrown as `SearchEngineError`

### Factory (P3, `Sources/AppCore/SearchEngineFactory.swift`)

`public enum SearchEngineFactory` with
`static func make(configuration: KaibaSearchEngineConfiguration?, environment: [String: String]) throws -> (any SearchEngine)?`.

- It returns nil when the configuration is absent or disabled.
- It throws `KaibaConfigurationError` for invalid configuration:
  - `invalid("searchEngine.kind")`, `invalid("searchEngine.url")`,
    `invalid("searchEngine.indexPrefix")`,
    `invalid("searchEngine.credentials")`
  - `missingEnvironmentVariable(name)`

### GraphQL SDL (P6; also used by P9 web)

Query fields, each on one physical line inside `type Query`:

```graphql
searchEngineCapability: SearchEngineCapabilityPayload!
engineSearchNotes(query: String!, notebookId: String, tagFilter: [String!], limit: Int, offset: Int): EngineNoteSearchQueryPayload!
relatedNotes(noteId: String!, limit: Int): EngineNoteSearchQueryPayload!
```

Types:

```graphql
type SearchEngineCapabilityPayload { result: ControlPlaneResult!, enabled: Boolean! }
type EngineNoteHit { note: Note!, snippet: String!, score: Float! }
type EngineNoteSearchQueryPayload { result: ControlPlaneResult!, value: [EngineNoteHit!] }
```

Result statuses:

- No engine: `accepted: false`, status `feature-disabled`, diagnostics
  `["search engine is not configured"]`.
- Engine failure: `accepted: false`, status `search-engine-unavailable`,
  diagnostics `["search engine unavailable"]`.

Limits:

- `engineSearchNotes.limit`: `0...200`, default 20.
- `engineSearchNotes.offset`: `0...1000`, default 0.
- `relatedNotes.limit`: `0...20`, default 8.
- Out-of-range values return `invalidVariable`.

## Shared execution rules (binding for every worker)

- **Workspace.**
  - All workers run on branch `main` in one working directory.
  - Workers run no git write commands, create no worktrees or branches,
    and do not commit, push or archive.
  - Workflow finalization owns commits.
- **Write scope.**
  - Edit only your plan's `writePaths`.
  - `sharedPaths` are read-only unless a `sharedPathNotes` entry grants a
    specific edit.
  - Never touch `.riela/`, lockfiles, other plans' files, or this index
    (P11 excepted).
  - Run no broad formatters.
- **Per-edit discipline.**
  - Before editing any file, fresh-read it and record
    `shasum -a 256 <file>` in your plan's Progress Log.
  - After editing, record the new hash.
  - If the pre-hash differs from your last read, someone else changed the
    file. Re-read it, re-derive your edit from this plan's intent, and log
    the drift.
- **Intent snapshot.** Before the first edit, copy your plan file to
  `tmp/search-engine-adapter/<P#>/plan-snapshot.md` and work from that
  snapshot.
- **Progress log.** Each worker appends only to its own plan's
  `## Progress Log`: each file edited with its pre and post hashes, each
  verification command with `exit=` and the log path, any blockers, and the
  done-criteria checklist.
- **Evidence.**
  - Logs go under the gitignored `tmp/search-engine-adapter/<P#>/`. Run
    `mkdir -p` first.
  - Re-runs use `attempt-<n>/` subdirectories and keep earlier logs.
  - Commands use bash-only `${PIPESTATUS[0]}`. Run them through `bash -c`.
  - A blank `exit=` is not evidence.
- **Swift tests.**
  - Swift tests need
    `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig`.
  - Run `mise run build` once first.
  - `bun` is reachable only through `mise exec`.
- **Peer breaks.**
  - Concurrent workers share one `.build`.
  - A compile failure in a file outside your `writePaths`, owned by an
    in-flight plan, is not yours to edit. Retry up to 3 times, about 2
    minutes apart.
  - After that, record `blocked by peer <planId>`. Do not record it as
    passed. P11 re-runs it.
- **AGENTS.md rules.**
  - English only, no emojis.
  - Swift files under 1000 lines. Check with `wc -l`.
  - Run `mise run lint` after Swift edits.
  - No machine-local absolute paths and no secrets in code, docs or logs
    that get committed.
- **Source snapshots and artifacts.**
  - Every declared path is a full-content source snapshot. Every plan
    declares `artifactRoots: []` in the manifest.
  - Build and tool outputs stay outside declared paths: `.build/`,
    `web/node_modules`, `web/dist`, `web/src-tauri/target`, the evidence
    root `tmp/search-engine-adapter`, and the Docker image and volume.
  - Never write generated, downloaded, binary or scratch files under
    `Sources`, `Tests` or `web/src`. P11's directory `sharedPaths` must stay
    under the 512-entry snapshot limit (about 492 projected).
- **Unconfigured regression guard.** No plan may change the behavior of
  `searchNotes`, `NoteSearch.swift` ranking, `NoteSearchLexicalFusion.swift`,
  or any existing GraphQL field.

## Completion criteria (whole feature)

- [ ] Every plan's done criteria are checked in its Progress Log, with
      exit=0 evidence.
- [ ] P11 reports a full `mise run check` with exit=0, plus `mise run lint`,
      `mise run web:check` and `mise run tauri:check` with exit=0.
- [ ] The gated live Elasticsearch test passes against `mise run search:up`.
      If Docker is unavailable, it is reported as blocked, never as passed.
- [ ] README has the "Optional search engine" section with the sample
      configuration.
- [ ] No Swift file has 1000 or more lines. `git status` shows only planned
      files, and `.riela/` is untouched.

## Progress Log

- 2026-10-04: Index and plans P1-P11 created from the accepted design (Step 3 accepted, comm-003677).
- 2026-10-04 (session-263 resume): The plans were re-verified against HEAD
  c381f1a. Since dc8244a only docs changed, and NoteStoreSchema.currentVersion
  is still 22. The design's SE6 was aligned to P7 (Step 3 re-accepted,
  comm-003686). The dispatch manifest was amended for the 0.1.6 contract:
  workflowExecutionId session-263, originalHead c381f1a, per-plan
  `artifactRoots: []`, artifactPolicy and snapshotBudget. Plans, waves,
  dependsOn, writePaths and sharedPaths are unchanged. All plans are still
  pending.
