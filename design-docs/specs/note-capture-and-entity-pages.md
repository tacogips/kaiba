# Anywhere Capture and Entity Pages

## Status

Accepted (2026-09-21) — implementation in progress; see
`impl-plans/active/note-capture-and-entity-pages.md`.

Accepted delta (2026-09-21, design review of starting material `ba7ef12`):
E1 was extended with the undo-snapshot rule (`captureNoteSnapshot` records
`canonicalTagIds`; `restoreNoteSnapshot` re-binds only tags still unbound so a
later promote is never reversed by undo) and the unfiltered
`idx_tags_canonical_note` index. The delta was introduced by the overrunning
planning run, verified against `Sources/AppCore/NoteService+ActionHistory.swift`
and the `tags` DDL, and is ratified as part of this design. The matching entry
lives in the plan's progress log.

Accepted deltas (2026-09-21, resumed-run design step; each closes a TASK-000
finding recorded in `tmp/note-capture-entity-pages-20260921-opus3/TASK-000/progress.md`):

- **C3 delta (closes F-000-2).** The Quick Memos singleton is scoped **per
  write principal** — one notebook per `(owner_user_id, library_id)` pair as
  bound by `writeOwnerUserId()` / `writeLibraryId()`, exactly the identity
  `ensureQuickMemoNotebook`'s insert already records. The lookup
  `quickMemoNotebookIds` must filter by that same scope; the multi-holder
  invariant applies within the scope only. Rationale: the store-wide lookup
  combined with `requireNotebookOwnership` made the first capturing account
  the sole owner and every other account's capture fail forever; per-principal
  scoping matches the per-user bearer credential and needs no operator-service
  bypass. Amended text in C3 below.
- **C6 delta (closes F-000-1 and F-000-3).** The contract adds **500** (the
  existing generic internal-error body) for any failure the note service
  raises on a request the route has already validated — including the C3
  singleton-invariant violation, which is a store defect, not a caller error.
  The route's `400` is produced **only** by the route's own body validation;
  the blanket `invalidInput → 400` mapping is removed. The previously
  implemented `404` arm (foreign singleton) is **removed** as unreachable
  under the C3 delta, together with its message constant and test. Amended
  text in C6 below.
- **C4 delta (closes F-000-6).** `ensureQuickMemoNotebook` publishes a
  `notebookCreated` change event on the run that actually creates the
  notebook (once ever per notebook), because `note-created` names a notebook
  id a viewer that never listed the notebook cannot interpret. Amended text
  in C4 below.
- **E6 delta (closes F-000-4).** `coOccurringTags` takes its limit as the
  root-field argument `tagDetail(tagId: String!, coOccurringTagLimit: Int)`
  rather than a nested field argument: this executor resolves a payload
  eagerly and then projects it, so nested field arguments are structurally
  unsupported. Nested-argument use is rejected and pinned by test. Amended
  text in E6 below.

The E4/E5 aggregation implementation threads the requested limit through
`NoteService.tagDetail(tagId:coOccurringTagLimit:)` so a non-default limit
computes the co-occurrence aggregate once, not twice (closes F-000-5; no
contract change).

## Summary

Two additions to the note subsystem, planned together as one work package:

- **F1 Anywhere Capture.** A phone or any browser on the LAN drops a thought
  into kaiba in one tap: an authenticated `POST /note/capture` endpoint on the
  existing `kaiba serve` HTTP server appends a note to a single accumulating
  **Quick Memos** notebook, identified by a system notebook-kind tag, with the
  existing auto-actions (auto-tagging) and the live events feed applying
  unchanged. A minimal capture page is a route of the existing web viewer SPA.
- **F2 Entity Pages.** Every tag becomes a destination. The existing
  route-addressed tag mode (`?tag=<tagId>`, `tag-detail-pane.md`) grows into
  the entity page: it already lists the tag's notes grouped by notebook; this
  design adds **co-occurring tags** and **promote-to-canonical-note** — one
  note designated as the tag's canonical description, backed by a nullable
  `canonical_note_id` column on `tags` — exposed on the CLI, the GraphQL API
  and the web viewer.

Both features were originally specified for riela's note subsystem before it
was extracted into kaiba (riela commit d4268c3). This document restates them
against kaiba as it exists today.

## Traceability

- Extends `kaiba-note.md` (domain model, HTTP note API), `note-api-auth.md`
  (client registration, bearer authentication), `tag-detail-pane.md`
  (tag mode pane T1–T6, tag-memo notebooks T4) and `web-chatbook-ui.md`
  (web viewer routes and panes).
- Auto-action behaviour follows `ai-agent-integration.md` (dispatch outbox).

## Current State (verified)

Corrections and confirmations of the commissioning brief, each grounded in a
symbol in this tree:

- **Transport half of F1 exists.** `ServerContracts.route(_:context:)`
  (`Sources/AppServer/ServerContracts.swift`) dispatches `POST /graphql`,
  `GET/POST /note/register`, `GET /note/events`, `GET /note/agent-stream`,
  `POST /note/agent-token`, `GET /healthz`; everything else is 405/404.
  There is **no `/note/capture`** route and no capture page.
- **Registration and bearer auth exist.** `NoteAPIAuthenticating` /
  `NoteAPIClientRegistering` (`Sources/AppServer/NoteAPIAuthenticating.swift`)
  with the one-use QR flow in
  `Sources/AppServer/QRClientRegistrationAuthenticator.swift`; CLI issuance in
  `runClientIssue` (`Sources/AppCore/CommandClients.swift`); unauthenticated
  serving is the explicit `allowUnauthenticatedNoteAPI` flag
  (`kaiba serve --allow-unauthenticated`, `Sources/AppCore/Command.swift`).
  Standard error bodies: `noteAPIUnauthorizedResponse` (401) and
  `noteAPIUnavailableResponse` (503).
- **The registration page precedent.** `KaibaStaticSPAHTTPRouter.response(for:)`
  (`Sources/AppServer/KaibaStaticAssetResolver.swift`) special-cases
  `GET /note/register` to serve the SPA bootstrap (path rewritten to `/`),
  because `/note` is otherwise a service prefix (`isKaibaSPAServicePath`).
- **Kind-tag singleton notebooks exist.** `bootstrapLongTermMemoryNotebook()`
  (`Sources/AppCore/NoteService+LongTermMemory.swift`) finds-or-creates the
  one notebook carrying `NoteStoreSchema.longTermMemoryNotebookKindTag` inside
  a single transaction, erroring if two notebooks carry the tag. Kind tags are
  seeded by `systemNotebookKindTags` (`Sources/AppCore/NoteStoreSchema.swift`);
  **no `quick-memo` kind exists** (`user-memo` exists but has different
  semantics — per-comment memo notebooks, `NoteService+MemoNotebook.swift`).
- **Auto-actions ride note creation already.** `NoteService.createNote`
  (`Sources/AppCore/NoteService.swift`) enqueues auto-actions
  (`enqueueAutoActions`, outbox + lease model in
  `Sources/AppCore/AutoActionDispatching.swift`; auto-tagging workflow
  `note-auto-tagging` seeded by `seedAutoActions`) and publishes change events
  consumed by `GET /note/events` (`NoteChangeFeed`). Nothing new is needed for
  a captured note to get live auto-actions.
- **Correction: a tag aggregation surface already exists.** The brief said
  kaiba has none. In fact `tag-detail-pane.md` is implemented:
  `NoteService+TagDetail.swift` (`tagDetail(tagId:)`, `listTagComments`,
  `ensureTagMemoNotebook(tagId:)`, `tagContextMarkdown`), GraphQL queries
  `tagDetail` / `tagComments`
  (`Sources/AppGraphQL/GraphQLContractProjector.swift`,
  `NoteGraphQLDocumentExecutor.swift`), and the web viewer tag mode
  (`web/src/components/TagPane.tsx`, `?tag=` in `web/src/router.ts`) whose
  Links tab already shows the tag's notes grouped by notebook (T6). F2 is an
  **extension of this surface**, not a new one. What is genuinely missing:
  co-occurring tags, the canonical-note binding, promote/unpromote, and a CLI
  detail surface.
- **Tags schema.** `tags(tag_id, name, class_id → tag_classes,
  parent_tag_id → tags, is_system, created_at)` with partial indexes on
  parent and class; assignments in `note_tags` / `notebook_tags` with
  covering indexes `idx_note_tags_tag(tag_id, note_id)` and
  `idx_notebook_tags_tag(tag_id, notebook_id)`
  (`Sources/AppCore/NoteStoreSchema.swift`). **No canonical-note column.**
- **Schema-change policy.** `NoteStoreSchema.currentVersion = 19`; the guard
  *recreates rather than upgrades* a legacy store
  (`unsupportedLegacyVersion`). In-place DDL change plus a version bump, no
  migration, matches repository policy.

## Design Decisions — F1 Anywhere Capture

- **C1 — Dedicated `POST /note/capture` route.** A new case in
  `ServerContracts.route` calling `routeNoteCapture`. *Rejected alternative:*
  reusing `POST /graphql` `createNote` from the capture page. Rejected
  because the capture client would have to know or choose a notebook id
  (createNote resolves `notebookId: nil` by creating a *new* notebook per
  call), the page would carry a GraphQL document builder for a one-field
  form, and the endpoint contract could not guarantee server-side Quick
  Memos resolution. A dedicated purpose route follows the existing
  `POST /note/agent-token` precedent and keeps the client contract minimal.
- **C2 — Authentication reuses the existing client mechanism verbatim.**
  The route authenticates through the injected `NoteAPIAuthenticating`
  bearer check exactly as `/graphql` does; phones acquire their credential
  through the existing one-use QR `/note/register` flow; when the server
  runs with `--allow-unauthenticated`, capture acts as the default user, as
  all other routes do. No capture-scoped tokens, no second registration flow
  (non-goal, and a parallel mechanism is prohibited).
- **C3 — Quick Memos is a kind-tag singleton notebook.** New system kind tag
  `notebook-kind:quick-memo` (constant `quickMemoNotebookKindTag` +
  stable id, appended to `systemNotebookKindTags` so every store seeds it).
  `NoteService.ensureQuickMemoNotebook()` copies the
  `bootstrapLongTermMemoryNotebook()` shape: one transaction that looks up
  notebooks carrying the kind tag via `idx_notebook_tags_tag`, errors if
  more than one, returns the existing one, otherwise creates a notebook
  titled `Quick Memos` and applies the kind tag (`provenance: .system`,
  `deletable: false`). *(Amended 2026-09-21, C3 delta:)* the singleton is
  scoped per write principal: the lookup joins `notebooks` and filters
  `owner_user_id = writeOwnerUserId() AND library_id = writeLibraryId()`,
  the same identity the creation insert binds, so every account (user in its
  active library) finds or creates **its own** Quick Memos notebook and the
  multi-holder invariant is evaluated within that scope. A different
  account's holder is invisible, never an error and never reachable.
  *Rejected alternatives:* title lookup (titles are
  user-mutable and not unique); reusing `notebook-kind:user-memo`
  (per-comment memo notebooks, different lifecycle); reusing the
  long-term-memory notebook (guarded, curated by consolidation).
- **C4 — Capture is an ordinary note write.**
  `NoteService.captureQuickMemo(bodyMarkdown:title:)` =
  `ensureQuickMemoNotebook()` + `createNote(notebookId: ...)`. Because it
  goes through `createNote`, auto-actions are enqueued and dispatched by the
  existing outbox (auto-tagging applies to captured notes with zero new
  mechanism) and `publishChange` feeds `GET /note/events`, so an open viewer
  updates live. No capture-specific auto-action configuration.
  *(Amended 2026-09-21, C4 delta:)* additionally, the run of
  `ensureQuickMemoNotebook` that actually creates the notebook publishes one
  `notebookCreated` change event, so a viewer that has never listed the
  notebook learns it exists; subsequent captures publish only `createNote`'s
  own `note-created`.
- **C5 — The capture page is an SPA route.** `GET /note/capture` serves the
  SPA bootstrap through the same rewrite-to-`/` special case
  `GET /note/register` already uses in `KaibaNoteFileHTTPRouterChain`; the
  SPA adds a `/note/capture` view: a textarea, a submit button, and reuse of
  the registered client's stored bearer credential from the existing app
  state (`web/src/state/appStore.tsx`). An unregistered visitor is sent to
  the registration flow. *Rejected alternative:* a standalone minimal HTML
  page — it would duplicate token storage, registration hand-off and event
  wiring the SPA already has.
- **C6 — Endpoint contract.** `POST /note/capture`, JSON object body:
  `text` (string, required, non-empty after trimming; bounded by the
  existing request-body cap `KaibaHTTPRequestParser.maximumBodyBytes`) and
  optional `title` (string). Responses:
  - `201` `{ "noteId": string, "notebookId": string, "noteNumber": int }`
  - `400` `{ "error": "capture request body must be a JSON object with a non-empty text string" }`
    (malformed JSON, missing/empty `text`, wrong types)
  - `401` — exactly `noteAPIUnauthorizedResponse` (existing shape)
  - `405` — the existing unsupported-method body for known paths
  - `503` — exactly `noteAPIUnavailableResponse` when no `NoteService` is
    configured, matching the other note routes
  - `500` — *(amended 2026-09-21, C6 delta)* the route's generic
    internal-error body for any error the note service raises on a request
    the route has already validated, including the C3 singleton-invariant
    violation ("multiple notebooks carry notebook-kind:quick-memo" within
    the caller's scope): that is a store defect and must not be reported as
    a client 400. The route's `400` is produced only by the route's own body
    validation. The earlier working-material `404` arm (foreign singleton)
    is removed as unreachable under the per-principal C3 delta.
  Oversized bodies are rejected by the existing parser before routing.
- **C7 — Security posture is unchanged.** Plain HTTP on the LAN, bearer
  tokens in the `Authorization` header, requests scoped to
  `NoteAPIAuthenticatedClient.userId` — identical to every existing note
  route. TLS, external auth, capture-scoped tokens, offline queue, share
  sheet and native apps remain non-goals. `text` is stored as markdown and
  rendered through the SPA's existing markdown pipeline (no raw-HTML
  injection path is added).

## Design Decisions — F2 Entity Pages

- **E1 — Canonical binding is a nullable column on `tags`.** The `tags` DDL
  gains `canonical_note_id TEXT REFERENCES notes(note_id) ON DELETE SET NULL`;
  `NoteStoreSchema.currentVersion` bumps 19 → 20. Per repository policy the
  guard recreates old stores; no migration, no shim. *Rejected alternative:*
  a `note_links.link_kind = 'canonical'` edge — links relate note↔note so
  the tag is not addressable as an endpoint, one-per-tag cannot be enforced
  by the schema, and it would overload the note graph's semantics. The
  column gives single-binding for free and `ON DELETE SET NULL` makes note
  deletion self-cleaning (`deleteNoteRows` needs no change; verified by a
  deletion test) — but *not* self-restoring: the clear happens inside the
  engine and never reaches the action log, so undo must carry the binding
  explicitly. `captureNoteSnapshot` therefore records the ids of the tags the
  deleted note was canonical for (`canonicalTagIds`) and
  `restoreNoteSnapshot` re-applies each one **only to a tag that is still
  unbound**, so a promote recorded after the deletion is never reversed by an
  undo (E2's last-promote-wins). The `tags` DDL carries
  `CREATE INDEX IF NOT EXISTS idx_tags_canonical_note ON
  tags(canonical_note_id)`: that reverse lookup, and the foreign key's
  `SET NULL` action itself, would otherwise scan `tags` once per deleted
  note. The index is deliberately unfiltered — SQLite does not use partial
  indexes for foreign-key actions. Notebook deletion needs no equivalent: it
  is already recorded `undoable: false` (U10), so there is no undo path whose
  bindings could be lost.
- **E2 — Promote and unpromote are explicit operations.**
  `NoteService.promoteTagCanonicalNote(tagId:noteId:)` validates that the
  tag exists, the note exists, and the tag is not a `folder`-class or
  `document-kind` (notebook-kind) tag — those are organizational, the same
  exclusion rationale as T1 — then sets the column (replacing any previous
  binding; last promote wins). `unpromoteTagCanonicalNote(tagId:)` clears
  it. Both publish a change event so the viewer refreshes. No
  auto-promotion (non-goal).
- **E3 — Canonical note creation reuses the tag-memo notebook.** Promote
  always takes an existing note. For "write a description now", the entity
  page offers *create description note*: create a note in the tag's memo
  notebook (`ensureTagMemoNotebook(tagId:)`, existing) and promote it in
  one flow. Promotion does **not** assign the tag to the note: the binding
  is the column, and a canonical note living in the tag-memo notebook stays
  out of the occurrence/History aggregates by T4's meta binding, which is
  correct — it is rendered in the entity header, not as an occurrence.
- **E4 — Co-occurring tags are an indexed aggregate, not a scan.** New
  service query `coOccurringTags(tagId:limit:)`:
  `note_tags a` filtered to `a.tag_id = ?` via
  `idx_note_tags_tag(tag_id, note_id)`, joined to `note_tags b` on
  `b.note_id = a.note_id AND b.tag_id <> a.tag_id` (each probe again via
  the `note_tags` primary key / tag index), grouped by `b.tag_id`, ordered
  by count descending, limited. Work is proportional to the tag's own
  assignment count times average tags-per-note — never the whole store.
  System kind tags and folder-class tags are excluded from the result (join
  against `tags.class_id`), matching T1. v1 counts the exact tag only;
  descendant expansion (the `tagComments` hierarchy CTE) is a possible later
  refinement, stated here so its absence is deliberate.
- **E5 — The entity page is the existing tag mode, extended.** The
  route-addressed `?tag=<tagId>` pane (T3) *is* the entity page: it is
  deep-linkable and already shows notes grouped by notebook (T6, reusing
  `notes(notebookId: nil, tagFilter:)`). This design extends
  `web/src/components/TagPane.tsx` with an entity header: the canonical
  note (rendered markdown excerpt + open link) or a promote control when
  none is bound, plus co-occurring tag chips that navigate to their own tag
  mode via the existing return stack. *Rejected alternative:* a separate
  center-reader page — it would duplicate the pane's data wiring and split
  the tag destination across two surfaces.
- **E6 — GraphQL surface.** `tagDetail` payload gains `canonicalNote`
  (nullable note projection) and `coOccurringTags` (list of
  `{ tag, count }`); *(amended 2026-09-21, E6 delta)* the limit is the
  root-field argument `tagDetail(tagId: String!, coOccurringTagLimit: Int)`
  — this executor resolves a payload eagerly and then projects it, so
  nested field arguments are structurally unsupported; a nested-argument
  selection is rejected (pinned by test) and the limit is threaded through
  `NoteService.tagDetail(tagId:coOccurringTagLimit:)` so the aggregate runs
  once. New mutations `promoteTagNote(input: { tagId, noteId })`
  and `unpromoteTagNote(input: { tagId })` returning the existing
  `NoteMutationPayload` shape (`GraphQLContractProjector.swift`,
  executor cases in `NoteGraphQLDocumentExecutor.swift`, operation
  allow-lists in `NoteGraphQLDocumentExecutorSupport.swift`).
- **E7 — CLI surface.** `CommandTags.swift`: `kaiba tag <name-or-id>`
  (`runTag`) additionally prints the canonical note (id + title) and top
  co-occurring tags; new subcommands `kaiba tag promote --tag <name-or-id>
  --note <note-id>` and `kaiba tag unpromote --tag <name-or-id>`, following
  the existing `tag define` argument conventions.
- **E8 — Non-goals restated.** No entity merge, rename, aliasing,
  auto-promotion or timeline views. Nothing in this design requires them.

## Data Flow

- **Capture:** phone → (once) QR register at `/note/register` → SPA stores
  bearer credential → `GET /note/capture` serves SPA → user submits →
  `POST /note/capture` (bearer) → authenticate → `captureQuickMemo` →
  `ensureQuickMemoNotebook` + `createNote` → auto-action outbox (auto-tag)
  + `NoteChangeFeed` → open viewers refresh via `GET /note/events`; page
  shows the created note id and clears for the next thought.
- **Entity page:** viewer opens `?tag=<tagId>` → `tagDetail` (now with
  canonical note + co-occurring tags) + existing Links/History/Memo tabs →
  promote/unpromote mutations update `tags.canonical_note_id` → change
  event → pane refreshes.

## Edge Cases

- Two concurrent first captures by the same principal:
  `ensureQuickMemoNotebook` is one serialized transaction; both return the
  same notebook, one creation event.
- Captures from two different accounts: each resolves or creates its own
  per-principal notebook (C3 delta); neither sees or errors on the other's.
- A second notebook carrying `notebook-kind:quick-memo` **within one
  principal's scope**: ensure fails loudly (same invariant shape as
  long-term memory) and the capture route answers 500 (C6 delta), never a
  400.
- Quick Memos notebook deleted: next capture recreates it (find-or-create).
- Capture with empty/whitespace `text`, non-object body, wrong
  content-type: 400 with the C6 body; oversized body: rejected by the
  existing parser cap.
- Unauthenticated capture without `--allow-unauthenticated`: 401
  (`noteAPIUnauthorizedResponse`); server without a note service: 503.
- Promote a note that is then deleted: `ON DELETE SET NULL` clears the
  binding; the pane falls back to the promote control.
- Promote onto a folder-class or notebook-kind tag: rejected with an
  invalid-input error (E2).
- Promote when a binding exists: replaced (last promote wins); unpromote on
  an unbound tag: no-op success.
- Tag deleted while promoted: the column lives on the tag row and vanishes
  with it (no dangling binding possible).
- Co-occurrence on a tag with zero notes: empty list, no error.

## Non-Goals

- F1: TLS, external auth providers, capture-scoped tokens, offline queue,
  share-sheet integration, native apps.
- F2: entity merge, rename, aliasing, auto-promotion, timeline views;
  descendant-expanded co-occurrence (deliberately deferred, E4).

## Verification

- **Schema:** store creation at version 20 seeds `notebook-kind:quick-memo`;
  `tags.canonical_note_id` accepts a note id and nulls on note deletion;
  legacy-version guard still refuses v19 stores.
- **Service:** `ensureQuickMemoNotebook` idempotency, duplicate-kind-tag
  failure, `captureQuickMemo` enqueues auto-actions and publishes a change
  event; `promoteTagCanonicalNote` validation matrix (missing tag/note,
  folder/kind tag, replace, unpromote); `coOccurringTags` ordering,
  exclusion of system/folder tags, and an EXPLAIN QUERY PLAN assertion that
  the query uses `idx_note_tags_tag` (no full `note_tags` scan).
- **Server:** route tests for `POST /note/capture` covering 201/400/401/405/503
  bodies and the `GET /note/capture` SPA rewrite.
- **GraphQL:** executor tests for the extended `tagDetail` payload and both
  mutations, including allow-list registration.
- **CLI:** `tag promote`/`tag unpromote`/`tag <name>` output tests.
- **Web:** vitest for the capture view (submit, error, unregistered
  redirect) and the TagPane entity header (canonical present/absent,
  co-occurring navigation); `tsc --noEmit`, lint, build stay green.
