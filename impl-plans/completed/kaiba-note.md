# Kaiba Note App Extraction

**Status**: Complete
**Design Reference**: `design-docs/specs/kaiba-note.md`

## Purpose

Extract the Riela Note domain (notes, notebooks, ontology tags, links,
comments, content-addressed files, FTS5 search) from
the `tacogips/riela` repository into kaiba as a standalone local-first
note application with a command line interface.

## Deliverables

- [x] `CKaibaSQLite3` system-library target exposing sqlite3.
- [x] `AppCore` containing the vendored SQLite wrapper and the full
      Riela Note domain (minus Riela-only workflow scaffolding), using
      CryptoKit instead of swift-crypto.
- [x] `AppCLI` implementing the `kaiba` note CLI per the design spec.
- [x] `AppCoreTests` containing the adapted `RielaNoteTests` suite plus
      CLI-focused tests.
- [x] Updated `architecture.md`, `command.md`, `README.md`.

## Tasks

### TASK-001: Vendor SQLite wrapper and system library

**Parallelizable**: No

**Completion Criteria**:

- [x] `Sources/CKaibaSQLite3/` modulemap + shim vendored from
      `CRielaSQLite3`, linked from `AppCore`.
- [x] `SQLiteDatabase.swift` vendored into `AppCore` with
      `import CRielaSQLite3` renamed; `swift build` passes.

### TASK-002: Vendor note domain into AppCore

**Parallelizable**: No (depends on TASK-001)

**Completion Criteria**:

- [x] All `Sources/RielaNote/*.swift` vendored except
      `NoteWorkflowScaffolder.swift`; `import RielaSQLite` dropped
      (same module) and `import Crypto` replaced with CryptoKit.
- [x] Default note root changed to `~/.kaiba/`
      (`KAIBA_NOTE_ROOT` env override).
- [x] `swift build` passes with no references to Riela-only modules.

### TASK-003: Vendor and adapt the note test suite

**Parallelizable**: After TASK-002

**Completion Criteria**:

- [x] `Tests/RielaNoteTests/*.swift` adapted into `Tests/AppCoreTests/`
      (imports renamed, libSQL-guarded sections removed or kept inert,
      scaffolder/API-client tests dropped only if they reference
      excluded code).
- [x] `swift test` passes.

### TASK-004: Implement the kaiba CLI

**Parallelizable**: After TASK-002

**Completion Criteria**:

- [x] `AppCommand` routes the full CLI surface from the design spec
      (add/edit/show/list/search/tag/tags/classes/tag-define/
      class-define/comment/attach/file/link/readonly/delete/notebook/
      storage) with `--note-root` / `KAIBA_NOTE_ROOT` resolution.
- [x] Text and JSON output modes; errors exit non-zero with a message.
- [x] CLI unit tests cover parsing and a full round-trip against a temp
      note root.

### TASK-005: Documentation and finalization

**Parallelizable**: After TASK-003, TASK-004

**Completion Criteria**:

- [x] `architecture.md`, `command.md`, `README.md` updated.
- [x] `task build`, `task test`, `swiftlint` pass; plan moved to
      `impl-plans/completed/`.

## Progress Log

- 2026-08-07: Plan created after studying
  `riela-note-design.md`, `design-riela-note.md`,
  `impl-plans/active/riela-note.md`, and the `RielaNote*` sources.
- 2026-08-07: All tasks completed. Vendored 30 domain source files plus
  `SQLiteDatabase.swift` into `AppCore` (renames: `import Crypto` →
  `CryptoKit`, `CRielaSQLite3` → `CKaibaSQLite3`, identifier strings
  `riela-note*` → `kaiba-note*`, meta namespace `rielaNote` →
  `kaibaNote`, "Riela System Memory" → "Kaiba System Memory").
  Excluded only `NoteWorkflowScaffolder.swift` and its two tests.
  Implemented the CLI router (`Command.swift`, `CommandSupport.swift`,
  `CommandNotes.swift`, `CommandTags.swift`, `CommandNotebooks.swift`,
  `CommandFiles.swift`) with text/JSON output. Verification:
  `swift build` clean; `swift test` 162 XCTest + 13 Swift Testing tests,
  0 failures; `swiftlint` 2 pre-existing large-tuple warnings (also
  present upstream), 0 serious; CLI smoke-tested end to end
  (add/edit/show/list/search/tag hierarchy filter/comment/attach/link/
  readonly/delete/notebook lifecycle/progress/file export/env root).
- 2026-08-07: Gap-check follow-up (two exploration agents cross-checked
  the extraction against riela sources and docs). Fixes: seeded default
  AI-tagging auto-actions are now disabled (kaiba has no dispatcher, so
  enabled seeds would grow the dispatch outbox on every write; tests
  re-enable them explicitly); added `kaiba storage gc`
  (reclaimUnreferencedFiles), `kaiba notebook readonly`, and
  `--sort`/`--created-after`/`--created-before` on search and notebook
  list. Confirmed already-vendored: schema v7 parent-scoped folder
  identity, `notes.title_source`, batch page ingest
  (`createNotebookWithNotes`), notebook-level read-only, first-note
  previews. Known library surface intentionally not CLI-exposed in v1:
  kanban boards, system memory, conversations, API-client registry,
  graph traversal, promoteCommentToNotebook. Test note: the vendored
  suite was written against enabled seeds, so the shared test helpers
  re-enable them (`enableSeededAutoActions`); a missed direct
  `NoteService(driver:)` construction initially deadlocked the
  delayed-dispatcher tests (await on a dispatch that never fires) —
  fixed by enabling seeds at every construction site. Final
  verification: swift build clean, 162 XCTest + 13 Swift Testing tests
  with 0 failures, swiftlint 2 pre-existing warnings.
- 2026-08-07: Web viewer + GraphQL + HTTP server port (user request:
  fully separate riela note into kaiba). Added `AppGraphQL` (10 note
  GraphQL files + JSONValue vendored; scaffoldNoteIngestionWorkflow
  mutation and workflow-registry principal stripped; note-only
  `GraphQLContractProjector.schemaContract`), `AppServer` (HTTP
  listener, route handler with /graphql, /note/register QR auth,
  /note/events long-poll, static SPA resolver; telemetry stripped;
  Riela* symbols renamed Kaiba*), `kaiba serve` command (async
  entry in AppCLI with stdout flush before the long sleep), and
  `web/` (SolidJS notes workspace vendored: notes/, NotesView,
  detail/search/compose components; App.tsx rewritten notes-only in
  cli-serve mode; client no longer hard-requires a bearer so
  --allow-unauthenticated hosts work). Verification: swift build;
  swift test 226 XCTest + 13 Swift Testing, 0 failures (includes 64
  vendored AppGraphQLTests); web: tsc clean, bun test 93 pass, vite
  build; end-to-end curl of /healthz, /graphql (list/tags), QR
  register → bearer → authenticated query, /note/events; Playwright
  screenshots confirm the viewer renders the notebook list and note
  detail pane against `kaiba serve --web-root web/dist` with zero
  console errors.
