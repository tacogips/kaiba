# Kaiba Note

## Status

Accepted

## Summary

`kaiba` is a standalone, local-first note application extracted from the
Riela Note subsystem (the `tacogips/riela` repository). Riela Note was
designed as an "external brain": an ontology-oriented note store where
notes live in notebooks, tags carry world-model classes and provenance,
notes link to each other, and attachments (images, page scans, videos,
source PDFs) are content-addressed files. Kaiba keeps that entire domain
core — data model, `NoteService` facade, FTS5 search, tag hierarchy,
file storage — and removes everything that only makes sense inside the
Riela runtime (workflow dispatch, GraphQL control plane, agent UIs,
server transport).

Kaiba ships as:

- `AppCore` — the note domain library (vendored and adapted from
  `Sources/RielaNote/` and `Sources/RielaSQLite/`).
- `AppGraphQL` — the note GraphQL executor (vendored from
  `Sources/RielaGraphQL/` note modules; the workflow-scaffold mutation
  and all riela control-plane surface removed).
- `AppServer` — local HTTP server (vendored from
  `Sources/RielaServer/`): `POST /graphql`, QR client registration
  (`/note/register`), long-poll change feed (`GET /note/events`), and
  static SPA serving.
- `kaiba` (`AppCLI`) — a command line note app over `AppCore`, plus
  `kaiba serve` for the HTTP note API and web viewer.
- `web/` — the SolidJS note viewer (vendored from riela `web/src`
  notes surface; workflow/agent/settings views removed). Built with
  vite; served by `kaiba serve --web-root web/dist`.

## Source Material

- `riela/design-docs/riela-note-design.md` — original requirements memo.
- `riela/design-docs/specs/design-riela-note.md` — accepted design
  (D1–D19); the data model and service semantics below follow it.
- `riela/impl-plans/active/riela-note.md` and the completed
  `riela-note-*` plans — implementation history; the extracted code is
  the accepted, test-covered implementation.
- `riela/Sources/RielaNote/`, `riela/Sources/RielaSQLite/`,
  `riela/Tests/RielaNoteTests/` — the vendored sources and tests.

## Design Decisions

- **K1 — Extraction by vendoring, not rewrite.** The Riela Note domain
  module already depends only on the small `RielaSQLite` wrapper plus a
  crypto library, and has an extensive test suite. Kaiba vendors those
  sources wholesale into `AppCore`, preserving type names (`NoteService`,
  `Note`, `Notebook`, `Tag`, ...) and behavior, so the accepted Riela
  design and its review history remain authoritative for domain
  semantics. Rejected: a fresh reimplementation (needless risk, loses
  hundreds of verified edge cases).
- **K2 — Single library module.** The SQLite wrapper
  (`SQLiteDatabase`) merges into `AppCore` instead of keeping a separate
  `RielaSQLite`-style target, matching kaiba's existing
  `AppCore`/`AppCLI` boundary. A new `CKaibaSQLite3` system-library
  target provides the sqlite3 C API.
- **K3 — CryptoKit replaces swift-crypto.** Kaiba targets macOS 14+
  only, so Apple CryptoKit provides the same `SHA256`/`HMAC<SHA256>` API
  without adding swift-crypto. The only external SwiftPM dependency is
  `anydoc-swift`, introduced by K9 for in-process document conversion.
- **K4 — Note operations are direct library calls.** Riela routed CLI
  note operations through its GraphQL executor because GraphQL was the
  shared control plane. Kaiba has no control plane; `AppCLI` calls
  `NoteService` directly.
- **K5 — Kaiba is the note app, so note commands are top-level.**
  `riela note add` becomes `kaiba add`; notebook/tag/class/file
  management are subcommand families (`kaiba notebook ...`,
  `kaiba tag ...`).
- **K6 — Auto-actions stay as inert configuration, seeded disabled.**
  The `auto_actions` table, the durable dispatch outbox, and the
  `AutoActionDispatching` seam are retained (they are part of the domain
  write path and its tests), but kaiba ships no workflow engine, so no
  built-in dispatcher consumes the outbox. Unlike Riela, the default
  AI-tagging actions are seeded with `enabled = 0`: only enabled actions
  enqueue outbox rows, so a standalone store does not accumulate
  dead pending dispatches on every write. External automation (e.g. an
  AI tagger) opts in by enabling an action and draining the outbox
  through `NoteService`. This preserves the Riela loop-guard semantics
  for any future dispatcher.
- **K7 — Excluded Riela-only surface.** Not vendored: workflow
  scaffolding (`NoteWorkflowScaffolder`), workflow dispatch
  (`RielaNoteDispatch`), GraphQL (`RielaGraphQL` note module), SwiftUI
  workspace (`RielaNoteWorkspace`/`RielaNoteUI`), the libSQL/Turso
  driver (`RielaNoteLibSQL`), and the remote note API server. The
  `NoteDatabaseDriving` seam remains, so a libSQL driver can return
  later.
- **K8 — Note root defaults to `~/.kaiba/`.** The store lives at
  `<note-root>/note-store.sqlite` with content files under
  `<note-root>/files/`. Override with `--note-root` or the
  `KAIBA_NOTE_ROOT` environment variable (highest precedence:
  `--note-root`, then env, then default).
- **K9 — Document import uses the `AnydocKit` Swift library.** `kaiba
  import` converts PDF/Office/EPUB documents to markdown in-process through
  a revision-pinned SwiftPM dependency. Build preparation compiles the
  dependency's Rust FFI; no converter executable or runtime path is required.
  Import is CLI-only (the HTTP server's
  2 MiB body cap rules out browser upload for now). See
  `document-import.md`.
- **K10 — Agent runtime lives in agent-gateway.** Kaiba owns an
  `AgentInvoking` protocol seam, the `ai` configuration section, prompt
  construction, reply validation, persistence, and all user surfaces;
  the concrete runtime is `tacogips/agent-gateway` (an ACP stdio
  agent), bridged by the process-spawned `AgentGatewayCLIInvoker`
  (landed 2026-08-12). When the binary or configuration is missing,
  every AI surface reports a clean "agent unavailable" state. See
  `ai-agent-integration.md`.
- **K11 — Imported documents split at H1 headings.** One note per H1
  section (fallback H2; single note when headingless), because headings
  are the only structure anydoc output retains, and H1 sections match
  the reader's chapter-sized units. Oversized sections split
  recursively under a 400 KiB guard.
- **K12 — Note-agent chat reuses conversation notebooks.** A chat about
  a note is an `agent-conversation` notebook whose turns are notes;
  subject binding via notebook meta JSON plus `source-citation` links;
  replies are produced through the auto-action outbox and delivered to
  clients via the existing change feed (no streaming, no new tables).
- **K13 — Chatbook web UI: hash routing and data-attribute grid.** The
  viewer's main screen is a three-pane foldable reader; routing is
  hash-based and pane layout is explicit `grid-template-columns` state
  owned by a shared store, replacing `:has()` selector magic. See
  `web-chatbook-ui.md`.
- **K14 — Tags are navigation subjects (2026-08-13).** The web reader
  underlines in-body occurrences of a note's attached tag names; tag
  clicks open a cross-notebook tag detail pane whose memos and agent
  chat bind to a lazily created per-tag `tag-memo` notebook. See
  `tag-detail-pane.md`.

## Domain Model (inherited from Riela Note D1–D19)

Kept unchanged; see `design-riela-note.md` for full rationale:

- Every note lives in a notebook; a standalone note is a single-note
  notebook (D3). Notebook kind (imported material, agent conversation,
  user memo) is a non-deletable system tag (D3/D6).
- Note title is derived from the first `# ` heading of the markdown
  body and cached in a `title` column (D4).
- Read-only notes block body edits and deletion but always allow
  comments, tags, and links (D5).
- Tag assignments record provenance (`human` | `ai` | `system`) and
  assigner; AI tagging can never overwrite or delete human tags (D6).
- Ontology = tag classes (`person`, `year`, `event`, `document-kind`,
  `topic`, `folder`); tags are globally unique names with at most one
  class (D7).
- Tags form a single-parent hierarchy; tag filters expand to the tag
  plus all transitive descendants, with cycle-safe traversal (D16/D17).
- Files are content-addressed records with `local` | `s3` storage
  locators; local→S3 migration (single and bulk) is supported; mixed
  storage is normal (D8). The S3 client is signed HTTP (SigV4), no SDK.
- Search is FTS5 (trigram) over title/body/tags with tag/class filters
  and a LIKE fallback for sub-trigram queries; results carry snippets,
  rank, and linked-neighbor expansion (D13).
- Note graph: explicit `note_links` rows with provenance; traversal
  utilities support bounded neighborhood expansion (graph-RAG
  primitive).
- System memory: a dedicated system notebook for structured
  agent/workflow memory records. Retained in kaiba as a library feature
  (usable by external tools), not exposed by the CLI in v1.

## Data Model (SQLite)

The schema is defined by `NoteStoreSchema.swift` and includes hierarchical
tags, the auto-action outbox, and API-client registry tables.
Database file: `<note-root>/note-store.sqlite`, WAL mode, FTS5 required.
Kaiba starts at the same schema version and reuses the guarded
additive-migration machinery, so an existing Riela note store opens
unchanged in kaiba.

## CLI Surface

```
kaiba [--note-root <dir>] <command> ...

kaiba add        [--notebook <id>] [--title <t>] [--body <md>|--body-file <path>|-]
                 [--tag <name>]... [--read-only]        # create note (new notebook when omitted)
kaiba edit       <note-id> (--body <md>|--body-file <path>) [--append]
kaiba show       <note-id> [--output json|text]         # body, tags, files, links, comments
kaiba list       [--notebook <id>] [--tag <name>]... [--limit N] [--offset N]  # created desc
kaiba search     <query> [--tag <name>]... [--class <id>] [--limit N]
kaiba tag        <note-id> (--add <name>... | --remove <name>...) [--class <id>]
kaiba tags       [--class <id>]                          # list tags
kaiba classes                                            # list tag classes
kaiba class-define <class-id> --label <label> [--description <text>]
kaiba tag-define <name> [--class <id>] [--parent <name>]
kaiba comment    <note-id> --body <text>
kaiba attach     <note-id> <file-path> [--role related|embedded|source-page-image]
kaiba file       <file-id> [--out <path>]                # resolve/export content
kaiba link       <from-note-id> <to-note-id> [--kind <kind>]
kaiba readonly   <note-id> --on|--off
kaiba delete     <note-id>                               # rejects read-only
kaiba notebook   list [--tag <name>]... [--sort <order>]
                 [--created-after <t>] [--created-before <t>]
                 [--limit N] [--offset N]
kaiba notebook   show <notebook-id>
kaiba notebook   create --title <t> [--kind <kind-tag>]
kaiba notebook   delete <notebook-id>
kaiba notebook   readonly <notebook-id> --on|--off
kaiba storage    migrate (<file-id>|--all) --profile <name>
                 --endpoint <url> --region <r> --bucket <b>
                 --access-key-env <VAR> --secret-key-env <VAR>
kaiba storage    gc [--grace-hours N]
kaiba --help | --version
```

Output is human-readable text by default; `--output json` prints stable
JSON for scripting. All commands honor `--note-root` /
`KAIBA_NOTE_ROOT`.

## HTTP Note API and Web Viewer

`kaiba serve [--host h] [--port p] [--web-root dir] [--allow-unauthenticated]`
starts a local HTTP server (Network.framework listener, default bind
`127.0.0.1:8787`):

- `POST /graphql` — the note GraphQL API executed by
  `NoteGraphQLDocumentExecutor` against the local note store. The
  schema is kaiba's `GraphQLContractProjector.schemaContract` (note
  domain only; riela's `scaffoldNoteIngestionWorkflow` and every
  workflow/manager surface removed).
- `GET|POST /note/register` — QR client registration. On start, serve
  prints a registration URL + terminal QR code; redeeming the code
  yields a bearer token stored hashed in `api_clients`. `--allow-
  unauthenticated` skips auth for trusted local use.
- `GET /note/events` — long-poll change feed backed by
  `NoteChangeFeed` wired as the store's change observer.
- Static SPA serving from `--web-root` (the built viewer), with SPA
  fallback for non-API paths.

The web viewer (`web/`) is the riela SolidJS notes workspace ported
minus riela-app-only surfaces: notebook navigation with folders,
hierarchical tags, read-only locks, note detail with markdown
reader/editor, search popup, compose panel, and live refresh via the
events feed. It always runs in the
`cli-serve` host mode against kaiba serve. A missing bearer no longer
blocks requests client-side: unauthenticated hosts accept them and
auth-required hosts answer 401 with the registration hint.

## Non-Goals (v1)

Superseded in part (2026-08-12): AI tagging, note-agent chat, and
document import are now in scope per K9-K13,
`ai-agent-integration.md`, `document-import.md`, and
`web-chatbook-ui.md`. Kaiba still ships no workflow engine; the
auto-action outbox plus the `AgentInvoking` seam remain the
integration points, and the concrete agent runtime stays external
(agent-gateway).

- No native GUI (the Riela SwiftUI module is designed to be portable; a
  kaiba app can host it later).
- No libSQL/Turso sync driver.

## Verification

- `swift build`, `swift test` (vendored `RielaNoteTests` adapted as
  `AppCoreTests`), `swiftlint`.
- CLI smoke: create/list/search/tag/attach/readonly/delete round-trips
  against a temp note root.
