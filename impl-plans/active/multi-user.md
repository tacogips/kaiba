# Multi-User Note Store

**Status**: In Progress
**Design Reference**: `design-docs/specs/multi-user.md`
**Decisions**: `design-docs/user-qa/multi-user.md`
**Related**: `impl-plans/active/note-api-auth.md`

## Purpose

One kaiba store should serve several people, each seeing their own notebooks,
while an unauthenticated host keeps working unchanged by acting as a single
default user. Writes must record who made them, and a `kaiba` invocation — in
particular one an agent makes on a user's behalf — must be able to act as a
named account.

## Deliverables

- [x] `users` table with a default user created when the store is created.
- [x] Notebook ownership, and per-user catalog reads.
- [x] `created_by` / `updated_by` on notebooks and notes, maintained on write.
- [x] API clients belong to a user and authenticate as that user.
- [x] `kaiba user` and `kaiba auth` commands.
- [x] `--jwt` / `--jwt-env` on every command.
- [x] Per-request scoping through the GraphQL executor.
- [ ] Ownership enforcement on by-id reads, bulk reads, and attached files, on
      the GraphQL surface and the file-byte route.
- [ ] `created_by` / `updated_by` exposed on the API models — plus
      `owner_user_id` on `Notebook` only.
- [ ] `POST /note/agent-token`: a server route handing an agent a token for the
      calling user.
- [ ] Docs and this plan reconciled with what actually landed.

**Scope boundary.** The ownership claim is the **GraphQL surface and
`GET /files/<fileId>`**. `GET /note/agent-stream` and `GET /note/events` never
enter `NoteService`, are not closed by this work, and stay open — recorded as
item 6 of `design-docs/specs/note-api-auth.md:115-124`, with no active plan
task covering them yet. Completing this plan is not closing the whole boundary.

**Also knowingly open: agent-chat tag grounding.** `tagContextMarkdown`
(`NoteService+TagDetail.swift:185`) pastes note bodies from every account
carrying a tag into one account's chat context
(`NoteService+AgentChat.swift:582`). It runs unscoped, on the dispatcher
service, so the design's `actingUserId != nil` rule leaves it out; see TASK-M06
Step 3 for the full reasoning. Closing it needs an acting user threaded into
the dispatcher — the same work TASK-M03's third criterion carries — and is not
done here.

**No schema change.** All columns this work reads already exist at
`NoteStoreSchema.currentVersion = 17`, and the token route adds no table. Under
the fresh-schema policy a version bump would refuse every existing store, so
nothing here may touch `currentVersion`.

## Tasks

### TASK-M01: Users table and default user

**Status**: Done

Schema version 11 adds `users` (unique email when present, one row allowed to
be default) and seeds `user-default` in `NoteStoreSchema.prepare`, idempotently.
Per the project's fresh-schema policy there is no migration: a version 10 store
is refused, not upgraded.

**Completion Criteria**:

- [x] A fresh store holds exactly one default user.
- [x] Re-preparing an existing store does not add another.
- [x] The default user cannot be disabled.

### TASK-M02: Notebook ownership and scoped reads

**Status**: Done

`notebooks.owner_user_id` on every insert path, plus `NoteService.actingUserId`
and `scoped(to:)`. `listNotebooks` filters on the owner when scoped; unscoped
stays the operator view of the whole store.

**Completion Criteria**:

- [x] Two scoped services see disjoint catalogs.
- [x] Unscoped sees both.
- [x] Unscoped writes belong to the default user.

### TASK-M03: Attribution columns

**Status**: Done

`created_by` / `updated_by` on `notebooks` and `notes`, maintained by every
insert and update, derived from the row's notebook owner.

**Completion Criteria**:

- [x] Create and update both record the acting account.
- [x] Existing suites still pass (404 XCTest, 32 swift-testing).
- [ ] Switch to the request's acting user when notebook sharing lands.

The third criterion stays **unchecked** when this plan is completed. The
stamping helpers already record the acting user; the remaining owner-derived
sites are the raw-SQL internal paths (long-term memory, agent chat) that run
unscoped, where the two values cannot diverge because sharing is a Non-Goal. It
must not be checked off on the grounds that sharing has not arrived
(`design-docs/user-qa/multi-user.md`, Pending).

### TASK-M04: API clients belong to a user

**Status**: Done

`api_clients.user_id`, `registerAPIClient(userId:)`, `client issue --user`, and
`NoteAPIAuthenticatedClient.userId` carried into the GraphQL request as
`actingUserId`. Unauthenticated requests resolve to the default user.

**Completion Criteria**:

- [x] A key issued for a user authenticates as that user.
- [x] A key cannot be issued for an unknown or disabled user.
- [x] Requests without a credential act as the default user.

### TASK-M05: `kaiba user` and `kaiba auth`

**Status**: Done

`user add|list|disable|enable`, `auth token issue`, `auth whoami`, and the
global `--jwt` / `--jwt-env` options resolved in `makeService`.

**Completion Criteria**:

- [x] `--jwt` scopes reads and writes for the whole invocation.
- [x] `--jwt-env` reads the token from the environment instead.
- [x] Combining both is refused.
- [x] A malformed, foreign, or disabled-account token is refused.

### TASK-M06: Ownership enforcement below the catalog

**Status**: Not started
**Parallelizable**: No — it is the security boundary TASK-M07 publishes account
ids onto, and it shares `NoteService+NotebookFiltering.swift` and the hydration
select lists with TASK-M07.
**Depends on**: nothing.
**Write scope**: `Sources/AppCore/NoteService+LibraryEnforcement.swift`,
`NoteSearch.swift`, `NoteService.swift`, `NoteService+Search.swift`,
`NoteService+Relations.swift`, `NoteService+TagDetail.swift`,
`NoteService+AgentChat.swift` (Step 3's `listAgentConversations` predicate),
`NoteService+NotebookFiltering.swift` (shared with TASK-M07, which is why the
two are serialized), `NoteGraph.swift`,
`Sources/AppServer/KaibaNoteFileHTTPRouter.swift`,
`Tests/AppCoreTests/`, `Tests/AppServerTests/KaibaNoteFileHTTPRouter*Tests.swift`.

`listNotebooks` filters by owner, but by-id reads do not. A caller who learns
another user's notebook or note id can still read it. Enforcement goes in the
layer library reach already uses, not a parallel one, and engages **only when
`actingUserId != nil`**. A refused row is reported **missing, not forbidden**,
reusing the wording `requireLibraryReach` already produces.

**Step 1 — by id.** Add the owner predicate to `requireNotebook`,
`requireNote`, `requireWritableNote`, and `requireWritableNotebook`
(`NoteService+LibraryEnforcement.swift:19-63`), resolving the row's notebook
and refusing when `owner_user_id` is not the acting user. Notes, comments,
links, and attachments reach their notebook through their note and are covered
by the same check.

Carve-out: the long-term memory notebook is exempt, keyed on the reserved tag
id `NoteStoreSchema.longTermMemoryNotebookKindTagId` and never on a
caller-supplied tag name.

**`requireNotes` (plural) must NOT gain the guard.** Despite the name it is a
batch *hydration* helper declared at `NoteService+Hydration.swift:66`, not one of the
four enforcement wrappers, and the naming invites exactly this mistake. A
guard there would **throw** where the design cuts a crossing by **filtering**:
`noteGraphNeighborsInDatabase` hydrates its result destinations through it
(`NoteGraphTraversal.swift:106`) *before* `graphNeighbors` applies
`filterReachable` (`NoteGraph.swift:70`), so a single link into another
account's note would fail the whole traversal instead of being dropped on the
way out. The same hazard as `listAgentConversations` in Step 3. Callers that
need a guard get it in their entry point (Step 2); bulk callers get the SQL
predicate (Step 3).

**Step 2 — close the `require*` bypasses.** A by-id read or write reached from
a public entry point must pass through `require*` **in that entry point**; a
free helper below it may keep `load*` for existence but must never be the only
guard. Two live bypasses (already library bypasses today, independent of this
work):

- `NoteService.linkNotes` (`NoteService+Relations.swift:5`, on GraphQL at
  `NoteGraphQLService.swift:394`) delegates to `linkNotesInDatabase`, which
  validates both endpoints with the unguarded `loadNote` (`:481-482`).
- The conversation-turn writer does the same for its source notes (`:353`, and
  `:358` via `requireNotes`, a hydration helper carrying no guard).

Both take the **read-level `requireNote`**, not the writable variant. A link
inserts into `note_links` and modifies neither note, and read-only notes are
ordinary — `NotePageDraft.readOnly` defaults to true
(`NoteModels.swift:152`), so imported document pages are read-only and agent
chat cites exactly such a page with `source-citation`. Reaching for
`requireWritableNote` would refuse a legitimate read-only endpoint.

**Step 3 — bulk reads.** The owner predicate goes in the SQL, next to the
library predicate, never as a post-query drop (which would silently shorten a
page). Add an owner-scope predicate helper beside `appendLibraryScopePredicate`
(`NoteSearch.swift:41-75`) and carry the acting user on `NoteSearchScope`
(`:17-35`) alongside `reachableLibraryIds`.

**The owner filter is keyed on `actingUserId != nil` alone, and is applied
outside the library predicate's unrestricted (nil) case.** This is the step's
most dangerous detail. `reachableLibraryIds` returns **nil** — meaning
"unrestricted", not "nothing to filter" — for the unscoped operator view
(`NoteService+LibraryEnforcement.swift:233-235`) *and for any acting admin*
(`:236-238`). The seeded default user **is** an admin, so an API client for the
default user and every `--as-admin` host take the nil path. Two existing sites
short-circuit on that nil, and nesting the new predicate inside either one
would silently disable ownership for exactly those callers:

- `reachableNoteIds` — `guard let reachableLibraryIds ... else { return
  Set(noteIds) }` (`:253-255`), which returns every id unfiltered.
- `searchComments` — the predicate sits inside `if let reachableLibraryIds`
  (`NoteService+Relations.swift:172`), so a nil skips it entirely.

The owner predicate must sit **above or beside** those branches, never within
them. Admin answers one question — may this account reach every library — and
ownership is not a library question (`design-docs/specs/multi-user.md`,
"Enforcement applies only when `actingUserId` is set"; Non-Goal: "Admin access
to another account's notebooks").

Sites to cover:

- `listNotes` (`NoteService.swift:690`).
- `searchNotes` (`NoteService+Search.swift:27`) through the four
  `appendLibraryScopePredicate` uses in `NoteSearch.swift:161, 267, 370, 485`.
- **`searchComments`** (`NoteService+Relations.swift:151-210`) — substring
  search over note-anchored and notebook-level memos, whose library predicate
  is the `if let reachableLibraryIds` at `:172-183`. It is **not** a
  `proposeLinks` query: `proposeLinks` (`:47`) scopes only through
  `filterReachable` (`:57`), listed separately below. `searchComments` is
  reached from the CLI (`CommandNotes.swift:183`, `kaiba search --memos`) and
  from agentic search (`AIAgenticSearch.swift:108`), not from GraphQL, so it is
  a `--jwt` caller's path to another account's memo bodies.
- The graph traversal exit filter — `reachableNoteIds` / `filterReachable`
  (`NoteService+LibraryEnforcement.swift:252-278`), reached from
  `NoteGraph.swift:70`, `NoteService+Relations.swift:57`, and
  `NoteService+LongTermMemory.swift:310`.
- The tag detail aggregates `listTagComments` and `tagDetail`
  (`NoteService+TagDetail.swift`) — **these two, not the whole file**.
  `listTagComments` (`:90`) takes no single alias: it unions a note arm and a
  notebook arm in one `WHERE` (`:114-116`), and both arms need the predicate,
  since covering only the note arm leaves notebook-level memos crossing the
  boundary. `tagDetail` (`:57`) counts through `taggedEntityCount` over
  `note_tags` and `notebook_tags` separately, so each count needs it too.

  **`tagContextMarkdown` (`:185`) is deliberately NOT covered**, and is named
  here so its absence is a decision rather than an oversight. Its query
  (`:197-206`) selects note **bodies** across every notebook in the store keyed
  on a global tag, guarded only by `requireTag` (`:190`), with neither a
  library nor an owner predicate — and it uses none of the three helpers, so
  the completeness grep does not find it either (the same miss class as
  `listAgentConversations`). It is out of scope because it is not a
  scoped-caller read: its only caller is agent chat (`NoteService+AgentChat.swift:582`,
  when a chat notebook's subject is a tag memo), which runs on the unscoped
  dispatcher service (`KaibaAutoActionDispatcher.swift:117`, built from the
  base service at `KaibaServerRuntime.swift:114`), so `actingUserId` is nil
  there and the design's `actingUserId != nil` rule does not engage. The
  consequence is real and is recorded with the other knowingly-open items
  below: every account's notes carrying that tag are pasted into one account's
  chat grounding. Closing it means threading an acting user into the
  dispatcher, which is the same acting-user work TASK-M03's third criterion
  carries.
- **`listAgentConversations`** (`NoteService+AgentChat.swift:432`, query at
  `:441-450`). It selects from `notebooks` with neither helper — so the
  completeness grep below does **not** find it — and then hydrates every row
  through `requireNotebook` (`:462`). Once Step 1 lands, a foreign row makes
  that call **throw** rather than drop the row, so a scoped caller's whole
  conversation list fails instead of returning its own. The owner predicate
  must go into the query itself, before the per-row hydration ever sees a
  foreign notebook.

**Completeness check** (record the output in the progress log):
`grep -rn "appendLibraryScopePredicate\|reachableLibraryIds\|filterReachable" Sources/`
— every hit is a bulk read that now carries an owner predicate, or is named
here as deliberately not carrying one. **The grep is a floor, not a ceiling**:
it only finds queries written with the existing helpers, and
`listAgentConversations` is the worked example of a bulk read it misses. Also
review by-hand any `SELECT ... FROM notebooks` or `FROM notes` that hydrates
rows a scoped caller will see.

**Step 4 — attachment bytes.** The predicate goes into `requireReachableFile`
(`NoteService+LibraryEnforcement.swift:69-97`), whose referencing-notebook
query is `getFileRecord`'s only path to a blob, so `GET /files/<fileId>`
inherits it. A blob referenced by more than one notebook stays readable when
**any** referencing notebook is the caller's, matching the library rule.

Ownership does **not** inherit the unreferenced-blob allowance at `:88-90`: an
orphan blob is refused to a scoped caller (fail closed) and still read by the
unscoped operator view. Nothing legitimate breaks — every `files` row is
inserted in the same transaction as its reference
(`NoteService+Files.swift:194-203`, `:254-263`,
`NoteService+AgentChat.swift:308-320`).

**Router change.** `KaibaNoteFileHTTPRouter.swift:75` resolves
`.scoped(to: authenticatedClient?.userId)` — **nil**, the unscoped operator
view — when the request carried no credential, while the GraphQL transport
resolves the same request to the default user (`ServerContracts.swift:259`,
`?? NoteStoreSchema.defaultUserId`). The router takes the **same default-user
fallback**. Without it the gate never engages on the file route of an
`--allow-unauthenticated` (or `--as-admin`) host, so GraphQL would refuse
another account's note while the route still served its attachment. Do not key
the gate on `isUnauthenticatedPrincipal` instead; library reach is unaffected
by the fallback either way.

**Completion Criteria**:

- [ ] A scoped service cannot read or mutate another user's notebook, note,
      comment, link, or file by id.
- [ ] A scoped service is refused when it names another account's note as
      either endpoint of `linkNotes`, and linking to a **read-only** note the
      caller owns still succeeds.
- [ ] `listNotes`, `searchNotes`, `searchComments`, graph neighbors,
      `proposeLinks`, `listTagComments` (both arms), `tagDetail`, and
      `listAgentConversations` return none of the other account's rows —
      `listAgentConversations` returning the caller's own list rather than
      throwing. This is a claim about those named reads, **not** about every
      read in `NoteService+TagDetail.swift`: `tagContextMarkdown` is
      deliberately outside it, for the reason given in Step 3.
- [ ] The same holds when the scoped caller is an **admin account**, including
      the seeded default user, which is the account `reachableLibraryIds`
      answers nil for. Ownership does not widen with the admin role.
- [ ] Attachment bytes are refused across users on an authenticated host **and**
      on an `--allow-unauthenticated` one; an unreferenced blob is refused to a
      scoped caller and still read unscoped.
- [ ] The unscoped service still reads both accounts; a single-account store
      behaves exactly as before.
- [ ] Internal bootstrap paths (long-term memory, agent chat) keep working.
- [ ] `requireNotes` (the batch hydrator) carries no ownership guard, and graph
      traversal still *filters* a crossing link rather than throwing on it.
- [ ] The completeness grep above is clean and recorded.

### TASK-M07: Expose attribution on the API

**Status**: Not started
**Parallelizable**: No — must land **after** TASK-M06.
**Depends on**: TASK-M06.

The API models follow the columns, and the columns differ per table:
`notebooks` carries `owner_user_id`, `created_by`, and `updated_by`; `notes`
carries only `created_by` and `updated_by`.

- **`Notebook` gains three fields**: `ownerUserId`, `createdBy`, `updatedBy`.
- **`Note` gains two**: `createdBy` and `updatedBy`. It gets **no**
  `ownerUserId` — synthesizing one means joining `notebooks` into every note
  loader, on the hottest read path in the store, to publish a fact the caller
  already reaches through `notebookId`.

All five are **optional with a default**, appended to the initializers on the
`libraryId` precedent (`NoteModels.swift:45`): a read that does not select the
columns leaves them nil rather than inventing the default user, and every
existing construction keeps compiling. The hydrators must **tolerate the
columns being absent**, not guard on them. `notebook(from:)` and `note(from:)`
(`NoteService+Hydration.swift:171`, `:190`, `:208`) are shared by every caller,
and two hydrator-fed select lists are **not** extended by this task — the
by-notebook `listNotes` (`NoteService.swift:661`) and the cross-notebook
`listNotes` overload (`:675`, select list at `:723`). A `guard let` on the new
columns would therefore break both.

Attribution is exposed **after** enforcement, never before: these fields name
accounts, and publishing an account id on a read path that is not yet closed
would widen the leak this work exists to close.

**Which reads must carry attribution, and which knowingly do not.** Optional
fields leave this ambiguous unless it is pinned, and "exposed on the API" must
not be tickable on by-id reads alone. This task extends exactly four select
lists, so:

- **Required non-null, directly** (the four select lists this task extends):
  `notebook` by id (`loadNotebook`, `NoteService+Hydration.swift:13`) — three
  fields; `note` by id (`loadNote`, `:32`) and the batch note hydration
  (`requireNotes`, declared at `:66` with its select list at `:73` — the
  batch **hydrator**, which Step 1 of TASK-M06
  explicitly leaves unguarded) — two fields; and the notebook catalog
  `notebooks`
  (`NoteService+NotebookFiltering.swift:100`) — three fields. Each needs a test
  asserting a real value, not merely a compiling field.
- **Required non-null, inherited.** Extending those two shared hydrators
  carries attribution into every read built on them, so these are required too
  and must be asserted, not assumed: `searchNotes` (`NoteSearch.swift:203`,
  `:322`, `:429`), graph neighbors (`NoteGraphTraversal.swift:46`, `:106`),
  long-term-memory recall (`NoteService+LongTermMemory.swift:438`, `:591`), and
  the conversation-turn source notes (`NoteService+Relations.swift:358`) all
  hydrate through `requireNotes`; `listAgentConversations`
  (`NoteService+AgentChat.swift:462`) hydrates through `requireNotebook` ->
  `loadNotebook`.

  **The inherited criterion may never be satisfied by narrowing `requireNotes`
  or `loadNotebook` back.** If a test expecting attribution on one of these
  reads fails, the fix is in the test's expectation or the caller — never in
  removing the columns from a shared hydrator, which would silently strip the
  batch and by-id reads this task exists to deliver.
- **Knowingly nil, recorded rather than fixed**: exactly two reads, both
  hydrator-fed select lists this task does not extend — the by-notebook
  `listNotes` (`NoteService.swift:661`) and the cross-notebook `listNotes`
  overload (`:675`, select list at `:723`). They report nil, which the design
  permits ("a read that does not select the columns leaves them nil"), but it
  must be written down rather than discovered later as a bug. Extending them is
  a follow-up, not this task.

  **Not on either list, because they are not reads of these models**: the
  `INSERT INTO notes` column lists at `NoteService.swift:274`, `:478`,
  `NoteService+ActionHistory.swift:276`, `NoteService+Relations.swift:376`,
  `NoteService+AgentChat.swift:285` and `NoteService+LongTermMemory.swift:527`
  already **write** `created_by`/`updated_by` via
  `(SELECT owner_user_id FROM notebooks WHERE notebook_id = ?)`, and the
  action-history snapshot at `NoteService+ActionHistory.swift:176` already
  selects both columns into a `JSONValue` without passing through
  `note(from:)`. None of them is affected by this task, and none can carry a
  nil-or-non-null assertion.

**Write scope**: `Sources/AppCore/NoteModels.swift`,
`NoteService+Hydration.swift` (select lists at `:13`, `:32`, `:73`; hydration
at `:171`, `:190`, `:208`), `NoteService+NotebookFiltering.swift:100`,
`Sources/AppGraphQL/GraphQLNoteSchemaContract.swift` (`Notebook` at `:12-17`,
`Note` at `:22`), `NoteGraphQLContracts.swift` (`GraphQLNotebookDTO` at
`:55-80`, `GraphQLNoteDTO`), `NoteGraphQLDocumentExecutorSupport.swift`
projection map (`Note` at `:477-488`, `Notebook` at `:489-500`),
`Tests/AppCoreTests/`, `Tests/AppGraphQLTests/`.

**Completion Criteria**:

- [ ] `Notebook` carries `ownerUserId`, `createdBy`, `updatedBy`; `Note`
      carries `createdBy`, `updatedBy` and **no** `ownerUserId`.
- [ ] The GraphQL contract exposes them as nullable `String` — three on
      `Notebook`, two on `Note` — and the field projection accepts them,
      asserted the way this repo already asserts contract shape
      (`XCTAssertTrue(GraphQLContractProjector.schemaContract.contains(...))`,
      e.g. `Tests/AppGraphQLTests/NoteGraphQLNotebookStatsTests.swift:42`). The
      contract is also served to clients at `ServerContracts.swift:280`, so the
      addition is visible on the wire and must be additive only.
- [ ] The four direct required-non-null reads (`notebook` by id, `note` by id,
      the batch note hydration, and `notebooks`) return real values, each
      asserted by a test.
- [ ] The inherited required-non-null reads (`searchNotes`, graph neighbors,
      long-term-memory recall, `listAgentConversations`) also return real
      values, asserted — and no shared hydrator select list was narrowed to
      make any assertion pass.
- [ ] The two knowingly-nil reads (both `listNotes` overloads) still return
      nil, and that fact is recorded in the progress log, so the deliverable is
      not read as store-wide attribution.
- [ ] Existing selections and existing fixtures keep working; no test is
      weakened or deleted to make this pass.
- [ ] `NoteStoreSchema.currentVersion` is still 17.

### TASK-M08: `POST /note/agent-token`

**Status**: Not started
**Parallelizable**: Yes — with TASK-M06 and TASK-M07. Its write scope
(`Sources/AppServer/ServerContracts.swift`, `KaibaServerRuntime.swift`, a new
`Tests/AppServerTests/` file) is disjoint from both, argued against the write
scopes as written. TASK-M06's source files are all under `Sources/AppCore/`
except `Sources/AppServer/KaibaNoteFileHTTPRouter.swift`, which this task does
not touch; its only `Tests/AppServerTests/` entry is
`KaibaNoteFileHTTPRouter*Tests.swift`, and this task's test file is a new one
for the token route. TASK-M07 is entirely `Sources/AppCore/`,
`Sources/AppGraphQL/`, `Tests/AppCoreTests/` and `Tests/AppGraphQLTests/`, and
names no AppServer file at all. TASK-M09 is docs only.
**Depends on**: nothing.

```
POST /note/agent-token
Authorization: Bearer <note API credential>
{"ttlSeconds": 900}          # optional
-> 200 {"token": "...", "userId": "...", "expiresAt": "...", "ttlSeconds": 900}
```

- **The account is never named by the caller.** The route mints for
  `NoteAPIAuthenticatedClient.userId`, the principal the note API already
  resolved, and reads no user field from the body. A route accepting a user
  parameter would let any credential mint a token for any account.
- **An unauthenticated request is refused**, including on a host started with
  `--allow-unauthenticated`: a minted token is a bearer credential that keeps
  working from elsewhere and outlives the flag being turned off.
- **TTL is bounded by the server.** Absent takes the server's short default; a
  present value may only shorten. A non-integral, non-positive, or over-long
  value is **refused, not clamped**. Both the default and the ceiling are new
  server constants — do not reuse `KaibaJWT.defaultTTLSeconds` (3600) as the
  route default, which is the ceiling's order of magnitude, not a short one.
- Add the route to the switch beside `/note/register`, `/note/events`, and
  `/note/agent-stream` (`ServerContracts.swift:148-157`), and add its path to
  the explicit 405 method-fallthrough tuple at `:158-159`.

**This route DIVERGES from its neighbours on authentication, deliberately.**
The existing `/note` routes all share one gate — `ServerContracts.swift:238-247`
(graphql), `:336-345` (`/note/events`), `:375-384` (`/note/agent-stream`) — of
the shape `if let noteAPIAuthenticator { ... } else if !allowUnauthenticatedNoteAPI { return noteAPIUnavailableResponse(...) }`.
Two flags, not one, decide the outcome, and they are **not** the same
condition: `KaibaServerRuntime.swift:169-171` nils the authenticator under
`--allow-unauthenticated`, but `:175` *also* passes
`allowUnauthenticatedNoteAPI: config.allowUnauthenticated` as **true**. On a
real `--allow-unauthenticated` host the `else if` is therefore false and the
request **proceeds with no `NoteAPIAuthenticatedClient`**.

Copying that gate here would produce exactly the route the design forbids: no
principal to mint for, so it either 500s or falls back to
`NoteStoreSchema.defaultUserId` — minting a portable bearer credential from an
open port. **This route refuses whenever no `NoteAPIAuthenticatedClient` was
resolved, whatever `allowUnauthenticatedNoteAPI` says, and must never take the
`?? NoteStoreSchema.defaultUserId` fallback that `:259` takes for GraphQL.**
That fallback is right for GraphQL (a read acting as the default user) and
wrong here (a credential that outlives the flag).

| Case | Status |
| --- | --- |
| Authenticated caller, valid TTL | 200 with `token`, `userId`, `expiresAt`, `ttlSeconds` |
| Authenticator nil **and** `allowUnauthenticatedNoteAPI == false` — a misconfigured host | 503, `noteAPIUnavailableResponse` (`NoteAPIAuthenticating.swift:52-59`), matching the neighbouring routes |
| Authenticator nil **and** `allowUnauthenticatedNoteAPI == true` — the real `--allow-unauthenticated` host | **503**, the same `noteAPIUnavailableResponse`. **This is the divergence**: the neighbours *proceed* here, and this route refuses. The status follows the design — "A host with no authenticator configured answers 503, the same answer the other `/note` routes give" — and an `--allow-unauthenticated` host is exactly a host with no authenticator configured. The two rows are separate because they are separate **configurations**, each needing its own test, not because they answer differently. |
| Authenticator present, credential absent or bad | the authenticator's own rejected response (401, `noteAPIUnauthorizedResponse` at `:43-50`) — the route returns it unchanged |
| Authenticated, but the account has since been disabled | 401, `noteAPIUnauthorizedResponse` — the credential no longer names an account that may be minted for |
| `ttlSeconds` non-integral, non-positive, or over the ceiling | 400 |
| Any other method on the path | 405, through the existing fallthrough tuple |
| Token-issuer seam not wired (nil) | 404, "agent token issuance is not enabled" — matching `/note/events` and `/note/agent-stream`. This is the **default** construction: the initializer defaults both existing optionals to nil (`ServerContracts.swift:116-130`), so it is the state `AppServerTests` hits unless the seam is passed. |

**The `--allow-unauthenticated` row must be asserted on a handler built for
it**, not on a default one: `DeterministicServerRouteHandler(noteAPIAuthenticator: nil, allowUnauthenticatedNoteAPI: true, ...)`.
The two rows share a status, so the test cannot be inferred from the status: it
is the *configuration* that differs, and only the second one exercises the
divergence. The initializer defaults that flag to `false`
(`ServerContracts.swift:119`), so a test that omits it asserts the
misconfigured-host row and passes green **without ever constructing the host
the design singles out by name**
(`design-docs/specs/multi-user.md`, The agent token route;
`design-docs/user-qa/multi-user.md`, "Which credential authorizes the agent
token route?"). That would leave the deliverable's headline guarantee untested.

The 401 for a disabled account is a **plan-level decision**: the design fixes
that it is refused (`issueAuthToken`, `NoteService+AuthTokens.swift:37`,
re-reads the user rather than trusting the credential) but not the status. 401
is chosen over 400 because the fault is the credential's standing, not the
request body.

**Seam.** `DeterministicServerRouteHandler` holds no `NoteService` today
(properties at `ServerContracts.swift:104-114`). Inject an optional
token-issuer seam beside `noteChangeFeed` / `agentReplyStreamHub` (`:113-114`) so `AppServerTests` can drive the
route without a store; `KaibaServerRuntime.swift:172-178` wires it from the
`service` value already in scope. A nil seam answers 404 "agent token issuance
is not enabled", matching its two neighbors. Derive `expiresAt` from the minted
token's `exp` (`KaibaJWT.verify`) rather than from a second clock read.

**Completion Criteria**:

- [ ] An authenticated caller receives a token for its own account and no
      other.
- [ ] Every row of the status table above is asserted: 200 success; 503 for a
      misconfigured host (authenticator nil, `allowUnauthenticatedNoteAPI`
      false); **503 for the real `--allow-unauthenticated` host, asserted on a
      handler explicitly built with `allowUnauthenticatedNoteAPI: true`** —
      a separate test case from the row above, since the two share a status and
      differ only in configuration; the authenticator's 401 for an absent or
      bad credential; 401 for a disabled account; 400 for an out-of-range TTL;
      405 for any other method; 404 for an unwired seam.
- [ ] The route never reads `NoteStoreSchema.defaultUserId`; a grep of the
      route body for `defaultUserId` returns nothing.
- [ ] An absent TTL takes the server default; an out-of-range, non-integral, or
      non-positive TTL is refused rather than clamped.

### TASK-M09: Spec citation correction

**Status**: Not started
**Parallelizable**: Yes — docs only, disjoint from every code task.
**Depends on**: nothing; may land first.

`design-docs/specs/multi-user.md:434` says the agent-stream/events gap "belongs
to `impl-plans/active/note-api-auth.md`", but that plan contains no task for it
— grepping it for `agent-stream`, `note/events`, change feed, and
`reachableLibraryIds` returns nothing. The gap is enumerated only at
`design-docs/specs/note-api-auth.md:115-124`. Restate it as: recorded as open
item 6 of the note-api-auth **spec**; no active plan task covers it yet.

**Completion Criteria**:

- [ ] The deferral cites the spec item, not a plan task that does not exist.
- [ ] The two other places the gap is recorded (the Ownership enforcement
      section, `design-docs/user-qa/multi-user.md` Pending) agree with it.

### TASK-M10: Doc and plan reconciliation

**Status**: Not started
**Parallelizable**: No — it records what actually landed.
**Depends on**: TASK-M06, TASK-M07, TASK-M08, TASK-M09.

Reconcile the spec's **Enforcement Status** and this plan with the delivered
state — and only the delivered state. Nothing moves from "being implemented
now" to "implemented" until its negative test under Verification passes.

- Move ownership enforcement, API attribution, and the token route into the
  implemented list, keeping the **"on the GraphQL surface and the file-byte
  route"** qualifier, which is load-bearing.
- Leave all "deliberately still open" items open, including the agent-chat tag
  grounding gap recorded under Scope boundary: agent-stream/events,
  `created_by`/`updated_by` under sharing (TASK-M03's third criterion,
  unchecked), per-user long-term memory, and library scope on the tag detail
  aggregates.
- Tick the Deliverables boxes above and set **Status: Complete** only when
  every completion criterion in M06–M09 is genuinely met.
- Append a progress-log entry (see below).

**Completion Criteria**:

- [ ] The spec's Enforcement Status matches the delivered state exactly.
- [ ] No deliverable is ticked whose test does not exist and pass.
- [ ] The four open items are still recorded as open.
- [ ] A progress-log entry names the suites run and their results.

## Verification

Run the narrowest suites first, then the full one. `swift test` needs
`PKG_CONFIG_PATH`.

```
mise run build
export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig
mise exec -- swift test --filter NoteUserTests
mise exec -- swift test --filter NoteLibraryEnforcementTests
mise exec -- swift test --filter KaibaJWTTests
mise exec -- swift test --filter KaibaNoteFileHTTPRouter
mise exec -- swift test --filter AgentChatTests
mise exec -- swift test --filter NoteTagDetailTests
mise exec -- swift test --filter NoteLongTermMemoryTests
mise exec -- swift test --filter DocumentImportTests
mise exec -- swift test --filter AppGraphQLTests
mise exec -- swift test
```

Tests each task owes:

- **TASK-M06, by id** (`Tests/AppCoreTests/`): a scoped service is refused
  another account's notebook, note, comment, link, and file by id, and is
  refused the mutation paths for the same ids; the unscoped service still reads
  both accounts; a single-account store behaves as before.
- **TASK-M06, links**: a scoped service is refused when it names another
  account's note as either endpoint of `linkNotes`, proving the boundary on the
  write path and not only on the read path. Linking to a **read-only** note the
  caller owns still succeeds — this pins the read-level semantics against a
  later drift to `requireWritableNote`.
- **TASK-M06, bulk**: `searchNotes`, `listNotes`, `searchComments`, graph
  neighbors, `proposeLinks`, both arms of `listTagComments`, `tagDetail`, and
  `listAgentConversations` return none of the other account's rows —
  `listAgentConversations` returning the caller's own list rather than
  throwing. Each is asserted **twice**: once with an ordinary scoped account,
  and once with a scoped **admin** account (the seeded default user is one),
  which is the caller `reachableLibraryIds` answers nil for and therefore the
  caller a predicate nested inside the library branch would silently miss.
- **TASK-M06, attachments** (`Tests/AppServerTests/`):
  `KaibaNoteFileHTTPRouter` answers 404 for a blob whose only referencing
  notebook belongs to another account and still serves one the caller owns —
  asserted on an authenticated host **and** on an `--allow-unauthenticated`
  one, the configuration where the router's acting-user fallback is what makes
  the check engage. A blob left with no referencing notebook is refused to a
  scoped caller and still read by the unscoped operator view.
- **TASK-M07** (`Tests/AppCoreTests/`, `Tests/AppGraphQLTests/`): writes record
  `created_by` / `updated_by` and the models carry them; `Notebook` reports
  `ownerUserId` and `Note` has no such field; the four **direct**
  required-non-null reads return real values, and so do the **inherited** ones
  (`searchNotes`, graph neighbors, long-term-memory recall,
  `listAgentConversations`); both `listNotes` overloads still return nil; the
  contract assertion follows the repo convention; existing selections are
  unaffected.
- **TASK-M08** (`Tests/AppServerTests/`): one assertion per row of the status
  table — 200 (success); 503 (authenticator nil **and**
  `allowUnauthenticatedNoteAPI` false, the misconfigured host); **503 on a
  handler constructed as `DeterministicServerRouteHandler(noteAPIAuthenticator: nil, allowUnauthenticatedNoteAPI: true, ...)`**,
  the real `--allow-unauthenticated` shape — this case is the deliverable's
  headline guarantee and needs its own test case, since it shares a status with
  the row above and differs only in configuration; 401 (absent or bad
  credential); 401 (disabled account); 400 (out-of-range TTL); 405 (any other
  method); 404 (token-issuer seam not wired, the default construction).
- **Not tested here, knowingly**: `GET /note/agent-stream` and
  `GET /note/events` remain unscoped, so no test asserts a cross-user refusal
  on either. A test claiming the boundary holds there would assert something
  this work does not deliver.
- **Manual**: `kaiba user add`, `kaiba auth token issue`, then
  `kaiba --jwt <token> notebook create` and `notebook list` showing one user's
  catalog against the unscoped operator view.

## Completion

This plan is Complete only when all of:

- Every completion criterion in TASK-M06 through TASK-M10 is checked, each
  backed by a test that exists and passes — except TASK-M03's third criterion,
  which stays unchecked by design.
- `mise exec -- swift test` passes in full, with no existing test weakened,
  skipped, or deleted to get there.
- `NoteStoreSchema.currentVersion` is unchanged at 17.
- The spec's Enforcement Status keeps the "GraphQL surface and the file-byte
  route" qualifier and still records all four open items.
- Only the files this work changes are committed.

## Progress Log

- 2026-08-16: TASK-M01 through TASK-M05 implemented and verified. `swift build`
  clean; 404 XCTest and 32 swift-testing tests pass, including 10 new
  multi-user tests and 10 new token tests. Verified end to end through the CLI:
  a fresh store seeds the default user, `auth token issue` mints a token,
  `--jwt` scopes the invocation, and one user's `notebook list` shows only their
  own notebooks while the unscoped view shows all. TASK-M06 and TASK-M07 remain;
  M06 is the security-relevant one.
- 2026-08-30: Plan reconciled against the accepted design
  (`design-docs/specs/multi-user.md`, `design-docs/user-qa/multi-user.md`).
  TASK-M06 expanded into its four enforcement steps with the file-level surface
  and the completeness grep; TASK-M07's column split corrected (Notebook three
  fields, Note two, no `Note.ownerUserId`); TASK-M08 added for
  `POST /note/agent-token`; TASK-M09 and TASK-M10 added for the doc citation
  fix and the final reconciliation. No code changed.

- 2026-08-30: Plan revised against the Step 5 review. TASK-M06 Step 3 now
  states that the owner filter is keyed on `actingUserId != nil` and sits
  outside the library predicate's nil short-circuit, naming the two sites where
  nesting it would disable it for admin callers (`reachableNoteIds` at
  `NoteService+LibraryEnforcement.swift:253-255`, `searchComments` at
  `NoteService+Relations.swift:172`); the mislabelled "`proposeLinks` candidate
  query" is corrected to `searchComments` with its CLI and agentic-search
  callers; `listAgentConversations` is added as a bulk site the completeness
  grep does not find; TASK-M07 pins the four required-non-null reads and
  records the rest as knowingly nil; TASK-M08 pins a status code per rejection.
  No code changed.

- 2026-08-30: Plan revised against the second Step 5 review. TASK-M07's
  attribution surface rebuilt on verified read paths: the knowingly-nil list is
  now exactly the two `listNotes` overloads (`NoteService.swift:661`, `:723`);
  the six `INSERT INTO notes` column lists and the action-history snapshot
  SELECT are named as not-reads rather than listed as nil; `searchNotes`, graph
  neighbors, long-term-memory recall and `listAgentConversations` are
  reclassified as required-non-null-by-inheritance through `requireNotes` and
  `loadNotebook`, with an explicit ban on narrowing either hydrator to make an
  assertion pass. TASK-M06's write scope gains `NoteService+AgentChat.swift`
  and `NoteService+NotebookFiltering.swift`, and TASK-M08's disjointness
  sentence is re-derived from the corrected list. A 404 nil-seam row is added
  to the TASK-M08 status table and to both the criterion and the test list.
  Four citation offsets corrected (`NoteModels.swift:45`, `:152`,
  `ServerContracts.swift:113-114`, `NoteService+TagDetail.swift:114-116`).
  No code changed.

- 2026-08-30: Plan revised against the third Step 5 review. TASK-M08's
  authentication contract corrected: the "same condition" claim is deleted, the
  single 503 row is split into two configurations — a misconfigured host and
  the real `--allow-unauthenticated` host — the route's deliberate divergence from
  the `ServerContracts.swift:238-247` / `:336-345` / `:375-384` gate is stated,
  the `?? NoteStoreSchema.defaultUserId` fallback is forbidden, and the
  `--allow-unauthenticated` row must be asserted on a handler built with
  `allowUnauthenticatedNoteAPI: true` rather than on the default. Both
  authenticator-nil rows answer 503, following the design's "a host with no
  authenticator configured answers 503"; the divergence is that this route
  refuses where the neighbours proceed, not that it answers differently. TASK-M06 Step 3 names `tagContextMarkdown`
  (`NoteService+TagDetail.swift:185`) as deliberately uncovered with its
  unscoped-dispatcher reasoning, the "both arms" completeness wording is
  narrowed to `listTagComments`/`tagDetail`, and the cross-account chat
  grounding is recorded under Scope boundary. Three offsets corrected
  (`Hydration.swift:66` for the `requireNotes` declaration, `:43-50` for the
  401 helper, `:148-157` for the route switch). No code changed.

**Each subsequent entry records**: the task id, what landed, the suites run and
their results, the completeness grep output for TASK-M06, and anything left
open with the reason.
