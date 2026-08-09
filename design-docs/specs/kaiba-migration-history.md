# Kaiba Migration History and Requirements Log

## Status

Living document — records the user directives that shaped kaiba and the
inventory of functionality ported from the Riela Note subsystem
(`tacogips/riela`). Update when new migration work lands.

## Directive Log

Chronological record of the instructions that drove the extraction
(2026-08-07):

1. **Initial extraction.** Extract the riela note functionality out of
   the riela repository and create a standalone note app named
   `kaiba`. Study the riela note requirements memo, design docs, and
   impl-plans; decide what kaiba should be; complete the
   implementation.
2. **Web viewer port.** Port the riela note web viewer (SolidJS) into
   kaiba as well — the full stack, including the GraphQL API it talks
   to (decision: "GraphQL ごとフル移植").
3. **Full separation.** The riela note functionality is being separated
   from riela permanently; port with that in mind (kaiba must not
   depend on riela, and riela will stop shipping the note subsystem).
4. **Ecosystem role.** Remove the note feature from riela; riela
   imports kaiba and uses it as an addon knowledge/context source.
   Migrate any riela-note features worth keeping into kaiba along the
   way. Kaiba runs standalone as a note web app (`kaiba serve`) and
   supports GraphQL data access from the `kaiba` command. Kaiba issues
   API keys and uses them for authentication/authorization. The riela
   kaiba addon exposes kaiba-client-equivalent functionality in a form
   that is easy to use from riela workflows.
5. **Documentation.** Keep this directive log and the migrated-feature
   inventory in kaiba's design docs (this file).

## Migrated Feature Inventory

Everything below was vendored from riela and adapted (renames,
dependency cuts); design authority for domain semantics remains riela's
accepted `design-riela-note.md` (D1–D19), mirrored in
`kaiba-note.md` (K1–K8).

### Domain core — `AppCore` (from `RielaNote` + `RielaSQLite`)

- Notes and notebooks (every note lives in a notebook; single-note
  notebooks for standalone notes; markdown bodies; derived titles with
  `title_source` derived/explicit preservation; note numbering).
- Ontology tags: tag classes (`person`, `year`, `event`,
  `document-kind`, `topic`, `folder`, ...), single-parent tag
  hierarchies with cycle-safe descendant-inclusive filtering,
  parent-scoped folder identity (schema v7 partial unique indexes),
  provenance tracking (`human`/`ai`/`system`), non-deletable system
  tags, notebook-kind tags.
- Relations: note links with provenance, link proposals, bounded graph
  traversal (`graphNeighbors`), comments (allowed on read-only notes),
  comment→notebook promotion.
- Read-only guards at note and notebook level.
- Kanban: status sets, per-tag status-set assignment, board queries,
  typed notebook progress with conflict detection
  (`expectedProgress`).
- Search: FTS5 trigram over title/body/tags, tag/class/date filters,
  sort orders, LIKE fallback for sub-trigram queries, linked-neighbor
  expansion, pagination.
- Files: content-addressed storage (sha256), local store with sharded
  layout + atomic writes, S3-compatible store via signed HTTP (SigV4,
  no SDK), mixed storage, single/bulk local→S3 migration,
  unreferenced-file GC with grace window.
- Conversations: `appendConversationTurn` (idempotency keys),
  `saveConversation`, conversation source-links.
- System memory: dedicated system notebook with structured
  workflow/stream-scoped records and persona-scoped context
  (library-level; CLI exposure deferred).
- Auto-actions: trigger configuration (`note-created`, `note-updated`,
  `notebook-created`), durable dispatch outbox with leases/heartbeats/
  recovery, loop guards. Kaiba change vs riela: default AI-tagging
  seeds ship **disabled** because kaiba has no dispatcher.
- Batch ingestion: `createNotebookWithNotes` (page-per-note import with
  page images and source documents — the PDF/book import primitive).
- Change observation seam (`NoteChangeObserving`) feeding the serve
  change feed.
- API client registry: hashed bearer tokens, authenticate/list/revoke
  (backs both QR registration and CLI-issued API keys).
- SQLite wrapper (`SQLiteDatabase`, WAL, FTS5/JSONB probes) and the
  guarded additive migration machinery (schema v7 parity with riela —
  an existing riela note store opens unchanged).

### GraphQL — `AppGraphQL` (from `RielaGraphQL` note modules)

- Document executor, document/operation/fragment parsing, strict
  variable validation, selection projection, DTO contracts, and the
  note-only authoritative SDL (`GraphQLContractProjector`).
- Removed vs riela: `scaffoldNoteIngestionWorkflow` mutation (riela
  workflow scaffolding), workflow-registry principal, manager/workflow
  control-plane surface, telemetry.

### HTTP server — `AppServer` (from `RielaServer`)

- Network.framework listener, HTTP request parser, deterministic route
  handler: `POST /graphql`, `GET|POST /note/register`,
  `GET /note/events` (long-poll change feed), `GET /healthz`; static
  SPA resolver with fallback; QR client-registration authenticator
  (terminal QR rendering included).
- `Riela*` symbols renamed `Kaiba*`; telemetry stripped.

### CLI — `AppCLI` + `AppCore` command router

- Riela's `riela note ...` family became top-level `kaiba` commands:
  add/edit/show/list/search/tag/tags/classes/tag-define/class-define/
  comment/attach/file/link/readonly/delete, notebook
  list/show/create/delete/progress/readonly, storage migrate/gc.
- New in kaiba (not in riela's CLI): `kaiba graphql` (execute note
  GraphQL documents locally), `kaiba client issue/list/revoke` (API
  keys accepted as serve bearer tokens), `kaiba serve` as a top-level
  command.

### Web viewer — `web/` (from riela `web/src` notes surface)

- SolidJS notes workspace: notebook list/board, folder tree, tag
  filters, kanban board with status sets, progress and read-only
  controls, note detail pane (markdown reader/editor, tags, links),
  search popup, compose panel, created-range filters, long-poll live
  refresh, QR/bearer registration flow.
- Kaiba changes vs riela: app shell rewritten notes-only (cli-serve
  host mode; workflow/agent/settings views removed); the client sends
  requests without a bearer so `--allow-unauthenticated` hosts work.

### Deliberately not migrated

- Riela workflow engine integration: auto-action workflow dispatcher,
  workflow scaffolding, note add-ons dispatched by riela's node
  adapter (these become riela-side kaiba addons instead).
- Note Agent / Note Config Agent chat UIs (need an agent runtime).
- SwiftUI workspace (`RielaNoteWorkspace`/`RielaNoteUI`).
- The former placeholder `RielaNoteLibSQL` target was not ported. Kaiba now
  provides its own real Turso/libSQL SQL-over-HTTP backend through
  `TursoNoteDatabaseDriver`, selected from the Kaiba configuration.
- Riela GraphQL control plane (manager mutations, workflow queries).

## Ecosystem Contract (kaiba ⇄ riela)

- Kaiba is the single owner of the note domain. Riela consumes kaiba —
  never the reverse.
- Riela-side kaiba addons act as workflow knowledge/context sources
  with capabilities equivalent to a kaiba client (search/get/create/
  tag/ingest), authenticated by kaiba-issued API keys against
  `kaiba serve`, or operating on a local note root.
- Auth: `kaiba client issue` mints the key (printed once, stored
  hashed); revocation is immediate; QR registration remains the
  browser-oriented path.

### Implemented riela integration (2026-08-07)

- Riela removed its note subsystem (RielaNote/RielaNoteLibSQL/
  RielaNoteWorkspace/RielaNoteDispatch targets, `riela note` CLI, note
  GraphQL module, server note routes, app note windows/settings, web
  note views) on branch `feat/extract-note-to-kaiba`, and now depends
  on kaiba `>= 0.1.1` via SwiftPM (`AppCore` + `AppGraphQL` products).
- Built-in `kaiba/*` addons in riela (vendored from the former
  `riela/note-*` addon implementations, running on the imported kaiba
  library): note-create/update/get/search/graph-neighbors/tag-apply/
  attach-file/comment-add/graphql-document, notebook-ingest-pages,
  note-conversation-save, kanban task-create/move/board,
  note-memory-save/load, note-persona-context-read/write.
- Note root resolution in addons: config `noteRoot` → workflow input →
  `KAIBA_NOTE_ROOT` → legacy `RIELA_NOTE_ROOT` → `~/.kaiba`.
- `kaiba/note-graphql-document` additionally supports remote mode:
  config `endpoint` targets a running `kaiba serve`, authenticated by
  the API key in the env var named by `apiKeyEnv` (default
  `KAIBA_API_KEY`); verified end-to-end including 401 on a revoked or
  wrong key.
- Kaiba-side prerequisite shipped in v0.1.1: the system-memory API
  (`appendSystemMemoryNote(s)`, `listSystemMemoryNotes`,
  `SystemMemoryNoteInput`/`SystemMemoryAttachmentInput`) became public
  so riela's memory/persona addons work across the package boundary.
- Riela's agent-trio/enterprise example workflows now reference the
  `kaiba/*` addon names.

### Memory responsibilities split with riela (2026-08-09, v0.1.4)

Memory ownership between riela and kaiba is now MECE: riela keeps
SHORT-TERM memory in its own SQLite store, and kaiba owns LONG-TERM
memory as consolidated notes in a canonical notebook, linked into the
`note_links` graph and recalled through FTS plus graph traversal.

- Removed the system-memory subsystem (`NoteService+SystemMemory.swift`,
  `NoteSystemMemoryTests.swift`): its newest-N-by-recency store keyed by
  `personaId`/`streamId`/`workflowId`/`nodeId` was short-term memory that
  only existed to serve riela's addons, and it moved back to riela. Gone
  with it: `appendSystemMemoryNote(s)`, `listSystemMemoryNotes`,
  `systemMemoryNotebook`, `SystemMemoryNoteInput`,
  `SystemMemoryAttachmentInput`, and the
  `notebook-kind:system-memory` seed. Existing stores keep the orphaned
  tag row; no migration deletes it.
- `setNotebookReadOnly` and the notebook read-only lock are generic
  notebook features and survive the removal, relocated to
  `NoteService+ReadOnly.swift` with their tests in
  `NoteReadOnlyLockTests.swift`.
- Added `NoteService+LongTermMemory.swift`: canonical "Kaiba Long-Term
  Memory" notebook identified by the non-deletable system tag
  `notebook-kind:long-term-memory` (class `document-kind`, provenance
  `system`, assigned by `kaiba-note`), bootstrapped idempotently from
  `NoteService.init` and guarded by the same single-identity invariant
  the system-memory notebook used. The notebook is NOT read-only locked.
- Public API: `longTermMemoryNotebook()`,
  `appendLongTermMemoryNotes(_:idempotencyKey:)`,
  `listLongTermMemoryNotes(periodStart:periodEnd:tagFilters:limit:)`,
  `recallLongTermMemories(query:limit:includeAssociations:associationDepth:)`,
  `linkLongTermMemoryAssociations(noteId:limit:)`, plus
  `LongTermMemoryEntryInput`, `LongTermMemoryAppendResult` and
  `LongTermMemoryRecallResult`.
- Append is one transaction with note ids derived from the idempotency
  key, so a retry replays instead of duplicating. Resolvable
  `sourceNoteIds` become `memory-source` links and resolvable
  `relatedNoteIds` become `related` links (both provenance `system`);
  ids that no longer resolve survive in the note metadata only.
- Schema v8 (append-only, `currentVersion` 7 -> 8) registers the
  long-term-memory kind tag on stores that predate it; new stores get it
  from the ordinary notebook-kind seed list.
