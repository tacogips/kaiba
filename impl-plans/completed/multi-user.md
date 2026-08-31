# Multi-User Note Store

**Status**: Complete — comm-000654 adversarial-review revisions are implemented
and verified; current gateway and retry-stream evidence is recorded below.
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
- [x] Ownership enforcement on by-id reads, bulk reads, and attached files, on
      the GraphQL surface and the file-byte route.
- [x] `created_by` / `updated_by` exposed on the API models — plus
      `owner_user_id` on `Notebook` only.
- [x] `POST /note/agent-token`: a server route handing an agent a token for the
      calling user.
- [x] Served event and reply streams scoped to the request principal.
- [x] Tag-grounded agent replies scoped to the originating principal.
- [x] Docs and this plan reconciled with what actually landed.

**Scope boundary.** Ownership now covers the **GraphQL surface,
`GET /files/<fileId>`, `GET /note/events`, and `GET /note/agent-stream`**.
The server scopes events and stream turns to the authenticated request
principal, and every queued AI auto-action retains the originating principal so
tag extraction, translation, and tag-grounded context use the same owner,
library, and internal-memory filters.

**Version-17-compatible cancellation table.** `NoteStoreSchema.prepare`
idempotently creates `auto_action_dispatch_cancellations` to record terminal
safety stops separately from the legacy dispatch-status CHECK. It is safe for
existing version-17 stores because `CREATE TABLE IF NOT EXISTS` runs during
prepare; it does not change `NoteStoreSchema.currentVersion` or introduce a
versioned migration. The token route itself adds no table.

## Execution Order

1. Start TASK-M06 and TASK-M08 concurrently; their declared source and test
   write scopes are disjoint.
2. Start TASK-M07 only after TASK-M06 passes its ownership-boundary tests, so
   account identifiers are not exposed before every covered read is scoped.
3. Complete TASK-M10 only after the ownership, token, served-route, and
   tag-grounding regressions pass.

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
- [x] `auth token issue` requires an enabled administrator or unscoped local
      operator; a scoped account can read only itself unless it is an enabled
      administrator.

### TASK-M06: Ownership enforcement below the catalog

**Status**: Done — Step 7 and adversarial review evidence through comm-000653 verified the ownership boundary; later gateway and stream hardening is recorded in the progress log below.
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
`NoteGraphTraversal.swift`, `NoteService+LongTermMemory.swift`,
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

Long-term memory remains store-wide only for unscoped internal processing.
Scoped callers receive the same missing-row result for its notebook and notes,
and its public listing/recall APIs are refused until per-user memory is
designed.

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

  **The tag-memo lookup is also covered explicitly.** Change
  `findTagMemoNotebookId` (`:241-250`) to accept the caller's owner scope and
  append `owner_user_id = ?` when `actingUserId != nil`. Both
  `ensureTagMemoNotebook` (`:151`) and `tagDetail.memoNotebookId` (`:79`) pass
  the service's acting user into that lookup. This makes the mutation find or
  create one memo notebook per account and tag, and makes the query return only
  that account's memo notebook id or nil. When a sole tagged source moves
  libraries, `ensureTagMemoNotebook` rehomes that same owner/tag memo before
  returning it, so `tagDetail` and the mutation retain one identity. A nil
  acting user preserves the current operator behavior: choose the earliest
  matching notebook store-wide.
  Do not rely on the later `requireNotebook` hydration guard; a store-wide
  lookup followed by that guard permanently prevents the second account from
  creating its own memo notebook.

  **`tagContextMarkdown` is now covered.** A queued reply retains its
  originating principal, and a tag-memo reply additionally selects the memo's
  inherited source library before reading tagged note bodies. Owner, reachable
  library, and internal-memory predicates run before the context limit, so a
  global tag cannot move protected content into a derived chat reply.
- **`listAgentConversations`** (`NoteService+AgentChat.swift`). It selects from
  `notebooks` with neither helper — so the completeness grep below does **not**
  find it — and then hydrates every row through `requireNotebook`. Once Step 1
  lands, a foreign or revoked-library row makes that call **throw** rather than
  drop the row, so a scoped caller's whole conversation list fails instead of
  returning its own. Both owner and current reachable-library predicates must
  go into the query before ordering and `LIMIT`, so inaccessible rows neither
  consume the page nor reach per-row hydration.

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

- [x] A scoped service cannot read or mutate another user's notebook, note,
      comment, link, or file by id.
- [x] A scoped service is refused when it names another account's note as
      either endpoint of `linkNotes`, and linking to a **read-only** note the
      caller owns still succeeds.
- [x] `listNotes`, `searchNotes`, `searchComments`, graph neighbors,
      `proposeLinks`, `listTagComments` (both arms), `tagDetail`, and
      `listAgentConversations` return none of the other account's rows —
      `listAgentConversations` returning the caller's own list rather than
      throwing or allowing a revoked-library row to consume its limit.
      Tag-grounded chat context is constrained by the originating principal
      and tag memo's inherited source library before its result limit.
- [x] For one tag shared by two accounts, `ensureTagMemoNotebook` creates or
      reuses a distinct notebook owned by each account;
      `tagDetail.memoNotebookId` returns only the caller's notebook id (or nil
      before that caller creates one), and the unscoped operator lookup still
      returns the earliest matching notebook store-wide.
- [x] The same holds when the scoped caller is an **admin account**, including
      the seeded default user, which is the account `reachableLibraryIds`
      answers nil for. Ownership does not widen with the admin role.
- [x] Attachment bytes are refused across users on an authenticated host **and**
      on an `--allow-unauthenticated` one; an unreferenced blob is refused to a
      scoped caller and still read unscoped.
- [x] The unscoped service still reads both accounts; a single-account store
      behaves exactly as before.
- [x] Internal bootstrap paths (long-term memory, agent chat) keep working.
- [x] API-client issue/list/revoke is a store-control operation; scoped
      ordinary and agent JWTs are refused, while enabled administrators and
      the unscoped local operator retain management access.
- [x] Library policy and membership mutations require an enabled administrator,
      unscoped operator, or current library owner in the same transaction.
- [x] Queued provider-derived writes verify the active outbox lease in their
      mutation transaction; a superseded worker cannot apply stale output.
- [x] `requireNotes` (the batch hydrator) carries no ownership guard, and graph
      traversal still *filters* a crossing link rather than throwing on it.
- [x] The completeness grep above is clean and recorded.
- [x] Queued chat, translation, and tag-extraction writes revalidate their
      originating account inside their mutation transactions; a disablement
      during provider invocation terminally cancels each workflow before it
      can persist output.
- [x] An edit-mode reply atomically replaces its subject and answers its turn,
      so a pre-completion failure rolls back both and a retry cannot reapply a
      partially committed edit.
- [x] Translation recovery identifies completed output by stable source-note
      id, retaining historical output for deleted sources while exposing exactly
      one current-version output for every remaining source. The output-write
      transaction supersedes obsolete same-source versions; completion
      transactionally revalidates the source/destination library boundary and
      current source-note set, so sources inserted during provider execution
      are translated before status becomes `completed`.
- [x] Account administration and store-global auto-action control require an
      enabled administrator or the unscoped local operator; unauthenticated
      and ordinary bearer-token scopes receive the missing-resource result.
- [x] Note and notebook tag removal authorizes the target before inspecting
      assignment provenance or deletability, so protected foreign assignments
      are indistinguishable from missing rows through AppCore and GraphQL.

### TASK-M07: Expose attribution on the API

**Status**: Done; direct and inherited attribution reads verified
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

- [x] `Notebook` carries `ownerUserId`, `createdBy`, `updatedBy`; `Note`
      carries `createdBy`, `updatedBy` and **no** `ownerUserId`.
- [x] The GraphQL contract exposes them as nullable `String` — three on
      `Notebook`, two on `Note` — and the field projection accepts them,
      asserted the way this repo already asserts contract shape
      (`XCTAssertTrue(GraphQLContractProjector.schemaContract.contains(...))`,
      e.g. `Tests/AppGraphQLTests/NoteGraphQLNotebookStatsTests.swift:42`). The
      contract is also served to clients at `ServerContracts.swift:280`, so the
      addition is visible on the wire and must be additive only.
- [x] The four direct required-non-null reads (`notebook` by id, `note` by id,
      the batch note hydration, and `notebooks`) return real values, each
      asserted by a test.
- [x] The inherited required-non-null reads (`searchNotes`, graph neighbors,
      long-term-memory recall, `listAgentConversations`) also return real
      values, asserted — and no shared hydrator select list was narrowed to
      make any assertion pass.
- [x] The two knowingly-nil reads (both `listNotes` overloads) still return
      nil, and that fact is recorded in the progress log, so the deliverable is
      not read as store-wide attribution.
- [x] Existing selections and existing fixtures keep working; no test is
      weakened or deleted to make this pass.
- [x] `NoteStoreSchema.currentVersion` is still 17.

### TASK-M08: `POST /note/agent-token`

**Status**: Done; status table and operational-failure mapping verified
**Parallelizable**: Yes — with TASK-M06 and TASK-M07. Its write scope
(`Sources/AppCore/NoteService+AuthTokens.swift`, `ServerContracts.swift`,
`KaibaServerRuntime.swift`, `Tests/AppCoreTests/KaibaJWTTests.swift`, and a new
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

- [x] An authenticated caller receives a token for its own account and no
      other.
- [x] Every row of the status table above is asserted: 200 success; 503 for a
      misconfigured host (authenticator nil, `allowUnauthenticatedNoteAPI`
      false); **503 for the real `--allow-unauthenticated` host, asserted on a
      handler explicitly built with `allowUnauthenticatedNoteAPI: true`** —
      a separate test case from the row above, since the two share a status and
      differ only in configuration; the authenticator's 401 for an absent or
      bad credential; 401 for a disabled account; 400 for an out-of-range TTL;
      405 for any other method; 404 for an unwired seam.
- [x] The route never reads `NoteStoreSchema.defaultUserId`; a grep of the
      route body for `defaultUserId` returns nothing.
- [x] An absent TTL takes the server default; an out-of-range, non-integral, or
      non-positive TTL is refused rather than clamped.
- [x] Concurrent real `NoteService` issuance on an unset store leaves every
      returned token resolvable through the one canonical signing secret.

### TASK-M09: Cross-plan citation reconciliation

**Status**: Done; TASK-408 shipment rechecked through comm-000616 deterministic delivery retention
**Parallelizable**: Yes — docs only, disjoint from every code task.
**Depends on**: nothing; may land first.

The reconciled authentication plan records TASK-408 as shipped. The completed
multi-user plan, authentication plan, and multi-user design now agree that
served event and reply streams are scoped and that a route-owned nonterminal
reply snapshot retains its terminal tail through final authorization.

**Completion Criteria**:

- [x] The shipped TASK-408 implementation and authoritative specs agree.
- [x] The completed-plan path is used by every cross-plan reference.

### TASK-M10: Doc and plan reconciliation

**Status**: Done; reconciled through passing comm-000610 implementation evidence
**Parallelizable**: No — it records what actually landed.
**Depends on**: TASK-M06, TASK-M07, TASK-M08, TASK-M09.

Reconcile the spec's **Enforcement Status** and this plan with the delivered
state — and only the delivered state. Nothing moves from "being implemented
now" to "implemented" until its negative test under Verification passes.

- Move ownership enforcement, API attribution, the token route, served event
  and reply streams, and tag-grounded agent context into the implemented list.
- Leave only `created_by`/`updated_by` under sharing (TASK-M03's third
  criterion) and per-user long-term memory open. Tag-detail comments,
  aggregates, and memo lookup are scoped by reachable library before their
  query limits and are implemented.
- Tick the Deliverables boxes above and set **Status: Complete** only when
  every completion criterion in M06–M09 is genuinely met.
- Append a progress-log entry (see below).

**Completion Criteria**:

- [x] The spec's Enforcement Status matches the delivered state exactly.
- [x] No deliverable is ticked whose test does not exist and pass.
- [x] The two remaining open items are still recorded as open.
- [x] A progress-log entry names the suites run and their results.

## Verification

Run the narrowest suites first, then the full one. `swift test` needs
`PKG_CONFIG_PATH`.

```
git diff --check
mise run build
mise run lint
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
- **TASK-M06, tag memo ownership**
  (`Tests/AppCoreTests/NoteTagDetailTests.swift`): create one shared tag and two
  scoped accounts; prove each account can call `ensureTagMemoNotebook`,
  receives a distinct notebook it owns, and sees only its own id through
  `tagDetail.memoNotebookId`. Assert nil before the second account creates its
  notebook, stable reuse on repeated ensure, and unchanged unscoped behavior
  selecting the earliest matching notebook store-wide. A derived memo inherits
  the sole reachable source library from either a note tag or a notebook tag;
  mixed-library sources are rejected rather than falling back to the open
  default library. Moving a sole tagged source reuses and rehomes the same
  owner/tag memo notebook, and `ensureTagMemoNotebook` and `tagDetail` report
  that same id. Rehoming requires retained account-level reach to the memo's
  current library; revoked access returns notFound and leaves the memo there.
- **TASK-M06, derived translations** (`Tests/AppCoreTests/AITranslationTests.swift`):
  a translation notebook and its translated notes inherit the authoritative
  source notebook library, so the unauthenticated default principal cannot
  read output derived from an authenticated source. Creation snapshots and
  rechecks the source library atomically; execution snapshots source content
  before provider invocation and revalidates source/destination equality in
  the output-write transaction. A provider failure after either notebook
  leaves the captured library does not persist provider-derived error text. A
  source deleted after provider invocation is treated as a stale snapshot, so
  the run refreshes and completes against the remaining current source set.
- **TASK-M06, derived conversations** (`Tests/AppCoreTests/`,
  `Tests/AppGraphQLTests/`): a non-idempotent turn's source notes and links
  share the destination conversation's library; new chat turns require their
  conversation and current subject to share a library; committed idempotent
  replays remain valid after source deletion. Edit-mode replacements compare
  the exact subject body captured for the provider and reject a concurrent
  human revision without overwriting it. Conversation creation validates and
  inserts its subject binding in one transaction, refusing a deleted or moved
  subject at the pre-insert boundary. The seeded default user's GraphQL
  boundary test covers protected existing-conversation appends, moved subjects,
  and notebook-level tag sources without exposing derived notebooks or turns to
  an unauthenticated principal. Conversation listing applies owner and current
  library-reach predicates before ordering and limiting, including after a
  member loses access to a protected library.
- **TASK-M06, attachments** (`Tests/AppServerTests/`):
  `KaibaNoteFileHTTPRouter` answers 404 for a blob whose only referencing
  notebook belongs to another account and still serves one the caller owns —
  asserted on an authenticated host **and** on an `--allow-unauthenticated`
  one, the configuration where the router's acting-user fallback is what makes
  the check engage. A blob left with no referencing notebook is refused to a
  scoped caller and still read by the unscoped operator view. Successful
  authorization-scoped file, event, and agent-stream responses send
  `Cache-Control: private, no-store`, so browser caches cannot outlive
  credential revocation or a library-access change.
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
- **TASK-408 and tag grounding** (`Tests/AppServerTests/`,
  `Tests/AppCoreTests/`): a served event feed omits foreign notebook and tag
  metadata; a foreign reply turn returns 404 before stream polling; a queued
  tag-memo reply includes only the originating account's tagged note bodies.
- **Manual**: `kaiba user add`, `kaiba auth token issue`, then
  `kaiba --jwt <token> notebook create` and `notebook list` showing one user's
  catalog against the unscoped operator view.

## Completion

This plan is Complete only when all of:

- Every completion criterion in TASK-M06 through TASK-M10 is checked, each
  backed by a test that exists and passes — except TASK-M03's third criterion,
  which stays unchecked by design.
- `git diff --check`, `mise run build`, `mise run lint`, and
  `mise exec -- swift test` pass, with no existing test weakened, skipped, or
  deleted to get there.
- `NoteStoreSchema.currentVersion` is unchanged at 17.
- The spec's Enforcement Status records all shipped served-route, tag-grounding,
  and tag-detail library boundaries and the two remaining open items.
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

- 2026-08-30: Step 2 design reconciliation completed TASK-M09. The deferred
  `/note/events` and `/note/agent-stream` boundary now cites note-api-auth
  TASK-408 consistently in the spec, user-QA, and both active plans; the routes
  remain explicitly outside TASK-M06 through TASK-M10. No runtime code changed.

- 2026-08-30: Step 4 self-review added `git diff --check` and `mise run lint`
  to the required implementation verification and completion gate. The
  filtered test list remains complete. No runtime code changed.

- 2026-08-30: Plan revised against the Step 5 review. TASK-M06 now explicitly
  scopes `findTagMemoNotebookId` by acting owner, carries that scope through
  `ensureTagMemoNotebook` and `tagDetail.memoNotebookId`, and requires a
  two-account test plus unchanged unscoped behavior. No runtime code changed.

**Each subsequent entry records**: the task id, what landed, the suites run and
their results, the completeness grep output for TASK-M06, and anything left
open with the reason.

- 2026-08-30: TASK-M06, TASK-M07, TASK-M08, and TASK-M10 implemented. M06
  adds scoped ownership enforcement to by-id guards, SQL bulk reads, graph
  exits, tag detail/memo lookup, agent conversations, and file bytes; the file
  router now defaults unauthenticated readers to `user-default`. M07 exposes
  `Notebook.ownerUserId`/attribution and `Note` attribution through hydration,
  GraphQL DTOs, schema, and projection. M08 adds authenticated
  `POST /note/agent-token` with a bounded 300-second default/900-second
  ceiling, no caller-supplied user, and 503 when authentication is absent even
  on an unauthenticated host. TASK-408, `tagContextMarkdown`, per-user
  long-term memory, and sharing attribution remain open as specified. Passed:
  `git diff --check`, `mise run build`, `mise run lint`, focused multi-user,
  GraphQL, server-route, library-member, file-router, and action-history tests,
  and `mise exec -- swift test` (526 tests). The TASK-M06 completeness grep
  found only the documented bulk-scope sites, all carrying ownership alongside
  library reach or explicitly deferred (`tagContextMarkdown`).

- 2026-08-30: Step 6 revision closed the implementation self-review findings.
  Conversation turn and saved-conversation source notes now establish
  `requireNote` ownership before linking; foreign read-only notes and notebooks
  are checked for ownership before their mutable state is evaluated. Added
  ordinary- and admin-scope coverage for the named bulk reads, source-link
  writers, per-owner tag memo lookup, and direct/inherited attribution
  hydrators. The token route now maps only account-standing failures to 401 and
  logs operational issuer failures before returning 500; its status table now
  covers both nil-authenticator configurations, absent/default, fractional,
  zero and negative TTLs, disabled-account refusal, and operational failure.
  M06-M08/M10 completion criteria are checked from this evidence. Deferred:
  TASK-408 (`/note/events`, `/note/agent-stream`), `tagContextMarkdown`,
  per-user long-term memory, and sharing-era attribution. Passed after the
  revision: `git diff --check`, `mise run build`, `mise run lint`, the focused
  M06-M08/M07 suites, the required filtered suites, and `mise exec -- swift
  test`; the TASK-M06 completeness grep remains limited to documented scoped
  sites and the explicit `tagContextMarkdown` deferral.

- 2026-08-30: Step 6 follow-up completed the acceptance matrix. Empty
  transcripts now validate `sourceLinks` before library inheritance; the M06
  tests cover scoped link endpoints, read-only owned links, source links,
  comments, direct files, orphan fail-closed behavior, a real two-hop foreign
  proposal candidate, caller-owned conversations, seeded-admin scope, and the
  unauthenticated open-library file route. M07 now asserts direct batch
  hydration and exact GraphQL contract/projection values; M08 verifies disabled
  account classification through `NoteService`. Passed focused ownership,
  GraphQL, file-router, JWT, conversation, and agent-token suites (59 tests),
  `NoteServiceAuthTokenTests` (5 tests), and `mise exec -- swift test` (535
  XCTest tests plus 34 Swift Testing tests).

- 2026-08-30: Step 6 integrity follow-up added direct ordinary-user and
  seeded-admin `getNotebook` foreign-owner refusal assertions, with unscoped
  access retained. It also verifies the production enabled-account
  `NoteService.issueAgentToken` path yields a resolvable JWT with matching
  subject, expiry, and 300-second TTL, and proves `/note/agent-token` ignores
  a hostile body `userId` in favor of the authenticated client. Focused and
  full verification passed: `mise exec -- swift test --filter
  'NoteLibraryEnforcementTests|NoteServiceAuthTokenTests|AgentTokenRouteTests'`
  (26 XCTest tests), `mise run build`, `mise run lint`, and `mise exec --
  swift test` (537 XCTest tests plus 34 Swift Testing tests).

- 2026-08-30: Step 7 review reopened TASK-M06 for two regressions. Agent-chat
  metadata readers now establish `requireNotebook` before reading a
  conversation's subject, and a two-owner GraphQL test confirms a foreign
  conversation produces the same `not_found` result with or without a supplied
  subject. Conversation-turn idempotency now finds an existing key before
  validating source notes, so a replay survives a deleted `turn.sourceNoteIds`
  source. TASK-M06 was rechecked as Done only after both regressions passed:
  `mise exec -- swift test --filter
  'AgentChatGraphQLTests|NoteServiceNotebookExpansionTests'` (28 XCTest tests).

- 2026-08-30: Step 7 follow-up restored legacy note-anchored memo search.
  `searchComments` now resolves both ownership and library reach through either
  a comment's `notebook_id` or its `note_id` notebook, so partial-copy rows
  with a null denormalized notebook id remain visible to their owner without
  exposing another account's rows. A seeded-admin regression test covers its
  own and a foreign null-notebook row. TASK-M06 was rechecked after `mise exec
  -- swift test --filter NoteLibraryEnforcementTests` passed (18 XCTest tests).

- 2026-08-30: Adversarial review follow-up closed the remaining ownership and
  token-initialization paths. Store-wide long-term memory is now internal-only
  for scoped callers (including GraphQL by-id lookup and public list/recall),
  links require both endpoints to be visible, and graph traversal applies the
  same owner/library scope at every expansion so foreign intermediates cannot
  affect results or paths. JWT first-use initialization now inserts a signing
  secret atomically and re-reads the canonical value before issuing. Rechecked
  TASK-M06 after GraphQL long-term-memory, cross-owner link/graph/proposal, and
  concurrent real issuer regressions passed: `mise exec -- swift test --filter
  'NoteLibraryEnforcementTests|NoteServiceAuthTokenTests|NoteGraphQLNotebookStatsTests'`
  (30 XCTest tests).

- 2026-08-30: Step 6 self-review reopened and rechecked TASK-M06. The reserved
  long-term-memory notebook is now excluded for every scoped principal,
  including the seeded default account and an unauthenticated service without
  an acting user; by-id, GraphQL, notebook/list/search, and link reads all
  return the missing-row boundary while unscoped consolidation remains intact.
  Graph owner/library predicates now run inside explicit, shared-tag, and
  lexical candidate queries before ranking and limits, and graph statistics
  use the same scope. Regression coverage saturates the explicit candidate
  limit with foreign rows and still finds the owned graph/proposal path. Passed:
  `mise exec -- swift test --filter
  'NoteLibraryEnforcementTests|NoteGraphQLNotebookStatsTests|NoteGraphTraversalTests'`
  (37 XCTest tests).

- 2026-08-30: Step 6 follow-up closed the remaining internal-memory memo
  surface. Scoped `searchComments` now excludes the reserved long-term-memory
  notebook through either comment anchor without dropping null-notebook legacy
  rows, and both `listTagComments` query arms exclude it before returning
  note- or notebook-anchored comments. Seeded-default and unauthenticated
  AppCore coverage, plus GraphQL `tagComments` coverage for both anchors,
  confirm the internal rows remain available only to unscoped processing.
  TASK-M06 was rechecked after `mise exec -- swift test --filter
  'NoteLibraryEnforcementTests|NoteGraphQLTagDetailTests'` passed (26 XCTest
  tests).

- 2026-08-30: Step 6 self-review follow-up closed internal-memory aggregate
  disclosure in `tagDetail`. Both note- and notebook-tag count queries now
  exclude the reserved long-term-memory notebook for every scoped principal,
  including seeded-default and unauthenticated scopes, while unscoped counts
  remain intact. AppCore and GraphQL regressions cover a topic-tag note count
  and the reserved-kind notebook count; the comment-search regression now
  compares result ids as a set because equal clock timestamps leave row order
  dependent on generated ids. TASK-M06 was rechecked after `mise exec -- swift
  test --filter 'NoteLibraryEnforcementTests|NoteGraphQLTagDetailTests|NoteTagDetailTests'`
  passed (36 XCTest tests).

- 2026-08-30: Adversarial-review follow-up closed forged agent-chat subject
  metadata. Parsing a conversation now validates the note or notebook subject
  through the caller's scope and confirms it is owned by the conversation
  owner, so an unscoped reply dispatcher cannot inherit a foreign subject from
  an attacker-owned notebook. Public GraphQL notebook creation rejects the
  server-managed `kaibaChat` metadata key. AppCore covers rejection before turn
  creation and legacy forged rows reaching the unscoped dispatcher without
  invoking the agent; GraphQL covers public metadata rejection plus a forged
  pre-existing conversation. TASK-M06 was rechecked after `git diff --check`,
  `mise exec -- swift test --filter 'AgentChatTests|AgentChatGraphQLTests'`
  (47 XCTest tests), `mise run build`, `mise run lint`, and `mise exec -- swift
  test` (552 XCTest tests plus 34 Swift Testing tests) passed.

- 2026-08-30: Step 6 self-review follow-up restored agent-chat idempotency
  after subject deletion. The turn path now authorizes its conversation and
  returns an existing idempotency-key match before revalidating a subject that
  may have been deleted after the original request; new turns still pass the
  scoped subject ownership checks before insertion and dispatch. Added an
  `AgentChatTests` replay regression and rechecked TASK-M06 after focused and
  full verification.

- 2026-08-30: Final review revision completed tag-grounded chat and TASK-408.
  Queued auto-action events retain the originating user and unauthenticated
  marker; the dispatcher uses that scope for reply generation, and
  `tagContextMarkdown` applies owner, reachable-library, and internal-memory
  predicates before its limit. The served event feed filters each event through
  the request's scoped service, and agent streaming authorizes the requested
  turn before polling. Added two-owner regressions for provider context, event
  metadata, and reply chunks. The plan moved to `impl-plans/completed/` and all
  three references were updated. Verification: `mise exec -- swift test
  --filter 'AgentChatTests|NoteEventRouteOwnershipTests'` passed (30 XCTest
  tests).

- 2026-08-30: Step 6 self-review follow-up closed recovery and deletion-event
  regressions. Recovered legacy chat-reply dispatches that lack the persisted
  principal marker now fail closed before invoking a provider; newly queued
  operator work remains explicit with a `false` marker. Notebook-deleted
  events carry a pre-delete owner snapshot that is kept internal to the feed,
  allowing the owner to receive the deletion refresh after the row is gone
  while foreign accounts receive no event. Added persisted legacy-dispatch and
  two-owner deletion-feed regressions; TASK-M06 and TASK-408 remain checked
  after `git diff --check`, `mise exec -- swift test --filter
  'AgentChatTests|NoteEventRouteOwnershipTests'` (32 XCTest tests), `mise
  exec -- swift test` (558 XCTest tests plus 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), and `mise run build` passed.

- 2026-08-30: Step 7 event-feed follow-up made authorization failures fail
  closed without advancing the returned revision: only `notFound` omits an
  event; operational reads return 500. Notebook-deleted events now retain both
  internal owner and library snapshots, then require the current caller to be
  the owner and still reach the library. Regressions cover unauthenticated
  access to an auth-required library, revoked membership, and injected
  authorization-read failure.

- 2026-08-30: Adversarial follow-up closes remaining served-event and queued
  reply boundaries. `/note/events` now uses opaque, principal-bound cursors:
  only an authorized event advances or wakes a cursor, preventing foreign
  activity from exposing global revision or timing. Recovered chat-reply work
  re-reads its stored principal and terminally cancels if that account was
  disabled before dispatch, without provider invocation or reply mutation.
  `tagMemoSubjectTagId` now enters `requireNotebook`, preserving owner and
  library reach indistinguishability. Added cursor wake, disabled-recovery,
  foreign-owner, and revoked-library regressions.

- 2026-08-30: Step 6 follow-up applies originating-principal validation before
  every queued AI workflow, not only chat replies. Recovered tag extraction and
  translation now fail closed for legacy rows and terminally cancel before any
  provider call or mutation when their originating account is disabled. Event
  cursor retention is bounded per principal, so one principal's reset-cursor
  churn cannot evict or wake another principal's long poll. Regressions cover
  disabled recovered tag extraction and translation plus cross-principal cursor
  pressure.

- 2026-08-30: TASK-408 follow-up bounds each opaque cursor's pending-event
  buffer. Overflow drops queued events and returns a resync only to the owning
  principal; an overflow regression confirms another principal's long poll is
  neither woken nor resynced.

- 2026-08-30: Replaced fixed scheduler-yield event-poll readiness probes with
  one-second `ContinuousClock`-bounded waits for both the feed's active-poll
  count and asynchronous publication revision. This preserves the
  foreign-event, cursor-pressure, overflow, and deletion assertions without
  depending on task scheduling luck.

- 2026-08-30: Retained owner-visible events when feed authorization fails.
  The failed poll returns 500 without a cursor, and a retry with the same
  opaque cursor reauthorizes and delivers the preserved event (or returns the
  existing principal-local resync on bounded-buffer overflow). Added a
  fail-once authorization regression for this no-loss retry contract.
  Verification: `git diff --check`, `mise exec -- swift test --filter
  NoteEventRouteOwnershipTests` (11 XCTest tests), `mise exec -- swift test`
  (570 XCTest tests plus 34 Swift Testing tests), `mise run lint` (two
  pre-existing non-serious warnings), and `mise run build` passed.

- 2026-08-30: Final adversarial follow-up isolates cursor capacity by
  authenticated account and client id, rejects reset pressure with 429 rather
  than evicting a live poll, and bounds unauthenticated allocation without
  eviction. Tag-grounding validation now identifies the one `.chat` request
  rather than depending on unrelated auto-tagging order. `/note/agent-token`
  requires JSON and returns `Cache-Control: no-store` on success. Verification
  passed: `git diff --check`, focused authorization suites (115 XCTest tests),
  `mise exec -- swift test` (573 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  web:check` (156 Bun and 34 Vitest tests), and `mise run tauri:check`.

- 2026-08-30: TASK-409 Content-Type validation now treats an explicitly empty
  header as non-JSON and returns 415 without indexing an empty media-type
  component. `AgentTokenRouteTests` covers the regression. Verification
  passed: `git diff --check`, focused authorization suites (116 XCTest tests),
  `mise exec -- swift test` (574 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  web:check` (156 Bun and 34 Vitest tests), and `mise run tauri:check`.

- 2026-08-30: Adversarial follow-up closes protected-library derived-content
  propagation. Agent-chat notebooks inherit the authorized subject library;
  tag-memo notebooks inherit a single reachable tagged-source library and
  reject mixed-library tags; tag-grounded replies use the memo's library; and
  saved conversations derive their library from both explicit and transcript
  source notes. The GraphQL regression proves the default unauthenticated
  principal cannot list or read protected-source conversations, turns, or tag
  memos. TASK-M06 remains checked after `git diff --check`, focused ownership
  suites (107 XCTest tests), `mise exec -- swift test` (576 XCTest and 34
  Swift Testing tests), `mise run lint` (two pre-existing non-serious
  warnings), and `mise run build` passed.

- 2026-08-30: Follow-up to comm-000469 closes the remaining derived-library
  gaps. Non-idempotent conversation turns now derive one actual source library
  from both `turn.sourceNoteIds` and source links and require it to match the
  existing conversation. New agent-chat turns reject a subject moved to a
  different library before a chat invocation or conversation mutation, while
  idempotent replay remains before mutable-subject validation. Tag-memo source
  derivation now unions `note_tags` and `notebook_tags`, inherits a protected
  notebook-only tag source, and rejects mixed libraries. The default-user
  GraphQL regression now covers protected existing-conversation appends, moved
  subjects, and notebook-level tags. Passed `git diff --check`, focused
  security suites (121 XCTest tests), `mise exec -- swift test` (579 XCTest
  and 34 Swift Testing tests), `mise run lint` (two pre-existing
  non-serious warnings), `mise run build`, `mise run web:check` (156 Bun and
  34 Vitest tests), and `mise run tauri:check`.

- 2026-08-30: Follow-up to comm-000471 closes the agent-chat dispatch-time
  library TOCTOU. Subject identity and context are now captured in one database
  transaction after subject/conversation library equality is checked, and reply
  persistence rechecks that equality in its own transaction. The agent-chat
  context responsibility moved to `NoteService+AgentChatContext.swift` so the
  primary chat service stays below the repository's 1000-line boundary.
  `AgentChatLibraryBoundaryTests` deterministically pauses provider invocation,
  moves the conversation, and proves no assistant reply is persisted in the
  now-open library. Passed `git diff --check`, focused security suites (122
  XCTest tests), `mise exec -- swift test` (580 XCTest and 34 Swift Testing
  tests), `mise run lint` (two pre-existing non-serious warnings), `mise run
  build`, `mise run web:check` (156 Bun and 34 Vitest tests), and `mise run
  tauri:check`.

- 2026-08-30: Follow-up to comm-000473 closes the streaming half of the
  agent-chat library TOCTOU. Every streamed chunk carries the immutable
  conversation library captured with provider context; `/note/agent-stream`
  rechecks both the current turn and that captured library after polling, so a
  protected conversation moved into the open library cannot disclose queued
  chunks. The deterministic route regression pauses a streaming provider,
  moves the conversation, and proves the unauthenticated principal receives
  404. Passed `git diff --check`, focused stream suites (23 XCTest tests),
  eight repeated streaming-boundary runs, `mise exec -- swift test` (581
  XCTest and 34 Swift Testing tests), `mise run lint` (two pre-existing
  non-serious warnings), `mise run build`, `mise run web:check` (156 Bun and
  34 Vitest tests), and `mise run tauri:check`.

- 2026-08-30: Follow-up to comm-000475 defers terminal-stream delivery
  acknowledgment until `/note/agent-stream` has reauthorized both the turn
  and captured provider-context libraries. A rejected post-move poll releases
  only its pending request obligation; it cannot make protected terminal data
  eligible for retention eviction. The route regression applies terminal
  retention pressure after an unauthenticated rejection and proves an
  authorized caller still receives the protected chunk. Verification passed:
  `git diff --check`, focused stream suites (24 XCTest tests), eight repeated
  regression runs, `mise exec -- swift test` (582 XCTest and 34 Swift Testing
  tests), `mise run lint` (two pre-existing non-serious warnings), `mise run
  build`, `mise run web:check` (156 Bun and 34 Vitest tests), and `mise run
  tauri:check`.

- 2026-08-30: Follow-up to comm-000479 revalidates the captured agent-chat
  subject and library before recording a provider failure. When that boundary
  has changed, no provider-derived failure text is persisted and the terminal
  stream carries the captured library even when no chunk was emitted. A
  deterministic no-chunk provider regression moves a protected conversation
  open before throwing a sensitive sentinel, then proves the sentinel is
  neither stored nor exposed through the unauthenticated stream route. The
  forged-subject regression now asserts `NoteServiceError.invalidInput`.
  Verification passed: `git diff --check`, focused stream and chat suites (54
  XCTest tests), eight repeated no-chunk failure runs, `mise exec -- swift
  test` (583 XCTest and 34 Swift Testing tests), `mise run lint` (two
  pre-existing non-serious warnings), and `mise run build`.

- 2026-08-30: Follow-up to comm-000481 makes failed-turn persistence compare
  the conversation's current library with the immutable provider-context
  snapshot, in addition to revalidating the subject identity and current
  subject/conversation equality. The deterministic no-chunk failure regression
  now moves both the protected subject and conversation to the open library
  before throwing its sensitive sentinel, proving that failure text is neither
  persisted nor available through the unauthenticated stream route. Verification
  passed: `git diff --check`, focused stream and chat suites (39 XCTest tests),
  eight repeated no-chunk failure runs, `mise exec -- swift test` (583 XCTest
  and 34 Swift Testing tests), `mise run lint` (two pre-existing non-serious
  warnings), and `mise run build`.

- 2026-08-30: Follow-up to comm-000483 applies the same immutable captured
  library check to successful reply persistence. The paused-provider boundary
  regression now moves both the protected subject and conversation to the open
  library before a successful reply returns, proving that the assistant reply
  remains unpersisted and the turn stays pending. Verification passed: `git
  diff --check`, focused stream and chat suites (54 XCTest tests), eight
  repeated successful-boundary runs, `mise exec -- swift test` (583 XCTest and
  34 Swift Testing tests), `mise run lint` (two pre-existing non-serious
  warnings), and `mise run build`.

- 2026-08-30: Follow-up to comm-000485 binds edit-mode subject mutation to the
  same immutable provider-context subject and library snapshot. The validated
  replacement now executes in one transaction with the normal guarded body
  write, preserving a valid committed edit if later turn persistence fails. A
  paused edit-provider regression moves both protected subject and conversation
  open before returning its replacement and proves the subject remains
  unchanged while the turn stays pending. Verification passed: `git diff
  --check`, focused stream and chat suites (55 XCTest tests), eight repeated
  edit-boundary runs, `mise exec -- swift test` (584 XCTest and 34 Swift
  Testing tests), `mise run lint` (two pre-existing non-serious warnings), and
  `mise run build`.

- 2026-08-30: Follow-up to comm-000490 adds optimistic concurrency protection
  for edit-mode replies. The provider-context snapshot retains the exact
  subject body used for an edit, and the replacement transaction compares it
  before writing. A paused-provider regression performs a concurrent human
  edit before the provider resumes, proves the AI reply fails with
  `NoteServiceError.conflict`, and preserves the human revision. Verification
  passed: focused `AgentChatLibraryBoundaryTests`, eight repeated stale-edit
  regressions, `mise exec -- swift test`, `mise run lint`, `mise run build`,
  and `git diff --check`.

- 2026-08-30: Follow-up to comm-000495 makes authorization-scoped attachment,
  event, and agent-stream success responses non-storable with `Cache-Control:
  private, no-store`. Agent-conversation creation now validates its note or
  notebook subject and inserts the derived notebook in one immediate
  transaction, with a pre-insert validation guard that refuses a deleted or
  moved subject. Regressions cover no-store headers and deterministic delete
  and move invalidation at the creation boundary. Verification passed: focused
  file, event, stream, and agent-chat boundary suites; `mise exec -- swift
  test`; `mise run lint`; `mise run build`; and `git diff --check`.

- 2026-08-30: Follow-up to comm-000500 revokes API access as soon as an
  account is disabled by authenticating API clients through an enabled-user
  join. Event and reply-stream long polls now reauthenticate the original
  bearer after waking and require the same client and user before delivering
  personalized output. Safety cancellation has a distinct persisted outbox
  outcome and terminalizes disabled-principal chat turns, translations, and
  reply streams instead of reporting dispatched work with pending domain
  state. Regressions cover a disabled previously-valid file credential,
  mid-poll client revocation for event and stream routes, and cancellation
  retry/re-enable behavior. Verification: focused security suites, full Swift
  suite, lint, build, web/Tauri checks, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000502 preserves a durable cancellation
  intent in cancelled chat and translation domain state, so recovery after an
  outbox-write boundary cannot reinterpret a safety stop as provider success.
  Event polls now restore an undelivered batch when post-poll authentication
  rejects it. Regressions cover chat and translation cancellation followed by
  account re-enable, plus transient-authentication and disabled/re-enabled
  same-cursor event retries. Verification: focused security suites (25 XCTest
  tests), eight repeated retry-suite runs, `mise run check` (594 XCTest and 34
  Swift Testing tests), `mise run build`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000506 makes disabled-principal tag extraction
  persist its leased `auto_action_dispatch_cancellations` row before returning
  cancelled, so a lost outer acknowledgement cannot retry it after account
  re-enablement. Agent-chat context now suppresses only intentional not-found
  reads and propagates operational failures. The version-17-compatible,
  idempotent cancellation table is documented above. Regression coverage
  simulates the lost-acknowledgement boundary for tag extraction. Verification
  passed: focused cancellation, agent-chat boundary, and event retry suites
  (32 XCTest tests); `mise run check` (595 XCTest and 34 Swift Testing tests),
  `mise run build`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000510 rechecked TASK-M06 after both required
  regressions passed. Translation notebooks now inherit their authoritative
  source library, including translated notes, so unauthenticated default-user
  reads of protected derived output fail closed. Tag-memo lookup keeps one
  owner/tag identity when a sole tagged source moves libraries by rehoming the
  existing memo before `ensureTagMemoNotebook` and `tagDetail` report it.
  Verification passed: focused `AITranslationTests|NoteTagDetailTests` (23
  XCTest tests), `mise exec -- swift test` (597 XCTest and 34 Swift Testing
  tests), `mise run lint` (two pre-existing non-serious warnings), `mise run
  build`, `mise run check`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000512 keeps TASK-M06 complete only after two
  deterministic boundary regressions passed. Translation creation now validates
  and inserts in one immediate transaction, snapshots source content before
  translation, and requires source/destination library equality in each output
  write transaction. Owner/tag memo identity remains stable across reachable
  moves, but an account whose old memo-library access is revoked receives
  notFound and cannot rehome it. Verification passed: focused
  `AITranslationTests|NoteTagDetailTests` (26 XCTest tests), `mise exec --
  swift test --quiet` (600 XCTest and 34 Swift Testing tests), and
  `git diff --check`.

- 2026-08-30: Follow-up to comm-000514 carries the immutable source library
  through translation failure handling. Failed-status persistence now
  transactionally requires the source and destination to remain in the
  captured library, so a provider error cannot be stored in a translation
  notebook moved from protected to open during invocation. The deterministic
  regression proves the sensitive failure sentinel remains absent from both
  owner and unauthenticated reads. TASK-M06 was rechecked only after focused
  translation tests (27 XCTest tests), the complete Swift suite (601 XCTest
  and 34 Swift Testing tests), lint, build, `mise run check`, and `git diff
  --check` passed.

- 2026-08-30: Follow-up to comm-000518 preserves GraphQL idempotent replay
  after a conversation subject is deleted. GraphQL now authorizes the existing
  conversation and returns its committed idempotency-key turn before resolving
  mutable subject metadata; non-replay sends retain full subject validation.
  Regression coverage proves the replay returns the same turn without a
  duplicate after subject deletion. TASK-M06 is rechecked after focused
  `AgentChatTests|AgentChatGraphQLTests` (51 XCTest tests), `mise run check`
  (601 XCTest and 34 Swift Testing tests, lint, web, and Tauri checks), `mise
  run build`, and `git diff --check` passed.

- 2026-08-30: Follow-up to comm-000522 preserves a pending TASK-408
  operational authorization failure when the same cursor overflows its bounded
  queue, and reports that failure before the retryable principal-local resync.
  A deterministic HTTP regression injects the failure, fills the queue, proves
  the first poll returns 500, and verifies the same cursor then returns
  `resync: true`. Verification passed: focused event-feed suites (19 XCTest
  tests), `mise run lint` (two pre-existing non-serious warnings), `mise run
  build`, `mise run check` (602 XCTest and 34 Swift Testing tests, lint, web,
  and Tauri checks), and `git diff --check`.

- 2026-08-30: comm-000526 reopened TASK-M06 and TASK-408 verification. Scoped
  library catalog counts now bind `notebooks.owner_user_id` for authenticated,
  admin, and unauthenticated principals, while the unscoped operator retains
  store totals; `libraries(forUser:)` uses the requested owner's count.
  Library, administrator, and membership authorization queries now throw so
  event-feed operational failures return 500 without advancing the opaque
  cursor. Focused service, GraphQL, and route regressions passed (21 XCTest
  tests), and `mise run check` passed (605 XCTest tests, 34 Swift Testing
  tests, SwiftLint, web, and Tauri checks). This plan remains active through
  renewed implementation review.

- 2026-08-30: comm-000530 excludes the internal long-term-memory notebook
  from every principal-scoped library aggregate, including `libraries(forUser:)`.
  Service and GraphQL coverage verify authenticated-default and
  unauthenticated-default counts exclude the reserved notebook while the
  unscoped operator count remains complete. The reply-stream cancellation
  regression now waits through a one-second `ContinuousClock`-bounded
  handshake instead of scheduler-yield spins. After repeated cancellation
  verification and the complete repository gate pass, this completed plan
  moves to `impl-plans/completed/multi-user.md`; its cross-plan references use
  that path. Verification passed: focused
  `NoteLibraryMemberTests|NoteGraphQLLibraryTests|AgentReplyStreamHubTests`
  (27 XCTest tests), 20 consecutive cancellation-regression runs, `mise run
  build`, and `mise run check` (Swift, SwiftLint with two pre-existing
  non-serious warnings, web, and Tauri checks).

- 2026-08-30: comm-000535 closes three retry and revocation boundaries. Every
  queued AI workflow revalidates its originating account inside post-provider
  mutation transactions, so an account disabled mid-dispatch terminally
  cancels chat, translation, and tag extraction before output persists.
  Edit-mode replacement and answered-turn persistence now share one
  transaction, so a pre-completion failure rolls both back and retry redoes
  the provider work only once. Translation recovery joins destination output
  to stable source-note ids instead of positional note counts; deleted sources
  retain historical output while each remaining source is translated exactly
  once. Deterministic blocking-invoker and failure-boundary regressions passed:
  `AgentChatDispatchSecurityTests|AgentChatLibraryBoundaryTests|AITranslationTests`
  (30 XCTest tests), including eight consecutive focused-suite runs.
  Verification passed: `mise exec -- swift test` (610 XCTest and 34 Swift
  Testing tests), `mise run lint` (two pre-existing non-serious warnings),
  `mise run build`, `mise run check` (Swift, SwiftLint, 156 Bun tests, 34
  Vitest tests, and Tauri checks), and `git diff --check`.

- 2026-08-30: comm-000540 makes TASK-408 event delivery replay-safe across a
  dropped HTTP response or overlapping use of the same opaque cursor. A cursor
  now retains its prepared owner-visible batch and returns a successor cursor;
  only use of that successor acknowledges the prior batch, while later events
  queue on the successor generation. HTTP-level regressions discard a prepared
  response and issue concurrent same-cursor polls, proving both retries retain
  the event and produce the same successor. Verification passed: focused
  event-feed suites (24 XCTest tests), eight consecutive delivery-retry runs,
  `mise exec -- swift test` (612 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  check`, and `git diff --check`.

- 2026-08-30: comm-000542 rechecks current event authorization before replaying
  a retained TASK-408 batch. Revoked library access omits cached notebook/tag
  metadata, and an operational authorization-read failure returns HTTP 500
  while retaining the original batch for same-cursor retry. Added deterministic
  dropped-response revocation and replay-failure regressions. Verification:
  focused event-feed suites (26 XCTest tests), eight repeated replay suites,
  `mise exec -- swift test` (614 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  check`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000546 makes concurrent long polls for the
  same TASK-408 cursor wait independently. When an owner-visible event arrives,
  every pre-publication waiter resumes; one prepares the retained delivery and
  the others replay the same event batch and successor cursor. HTTP regression
  coverage verifies two registered same-cursor polls before publication.
  Verification passed: focused event-feed suites (26 XCTest tests), eight
  repeated overlap runs, `mise run check` (614 XCTest and 34 Swift Testing
  tests, SwiftLint with two pre-existing non-serious warnings, web, and Tauri
  checks), and `git diff --check`.

- 2026-08-30: comm-000550 closes the translation false-completion race. Before
  setting `completed`, the translation transaction revalidates the captured
  source/destination library and confirms every current source note has output;
  a new source refreshes the snapshot and is translated before completion. A
  deterministic provider-time insertion regression proves the resulting
  translation has both outputs. TASK-M06 is rechecked after focused
  `AITranslationTests`, repeated regression, full Swift, lint, build, complete
  repository checks, and `git diff --check` pass.

- 2026-08-30: comm-000555 closes scoped control-plane escalation and protected
  tag ownership oracles. Account creation, disablement, role changes, and
  account lists now require an enabled administrator or unscoped local
  operator; global auto-action reads, mutation, dispatch inspection, and
  recovery use the same boundary. Note and notebook tag removal now authorize
  the target in the mutation transaction before resolving assignment policy.
  Regressions cover ordinary and agent-token CLI account management, scoped
  GraphQL auto-action control and cross-user dispatch, and foreign protected,
  AI, non-deletable, and absent tag assignments by name and id. Verification
  passed: focused `NoteUserTests`, `NoteLibraryEnforcementTests`,
  `AutoActionTests`, `NoteGraphQLControlPlaneSecurityTests`, and
  `CommandCLITests` (69 XCTest and 18 Swift Testing tests); `mise run check`
  (621 XCTest and 35 Swift Testing tests, SwiftLint with two pre-existing
  non-serious warnings, web, and Tauri checks); and `git diff --check`.

- 2026-08-31: comm-000557 closes the remaining JWT-to-administrator escalation
  and individual-account enumeration paths. `auth token issue` now preserves
  the command's JWT scope and `NoteService.issueAuthToken` transactionally
  requires an enabled administrator or unscoped local operator. Login and
  token-resolution use module-internal raw account lookup helpers, while public
  `user(id:)` and `user(email:)` expose only the acting account to a scoped
  non-admin (foreign and missing accounts both return nil). Regressions cover
  ordinary and agent JWT CLI issuance attempts, attempted administrator
  creation, direct service issuance, foreign id/email lookup, enabled-admin
  lookup, and email-login token issuance. Focused
  `NoteUserTests|NoteServiceAuthTokenTests|CommandCLITests|EmailLoginTests`
  passed (35 XCTest and 18 Swift Testing tests); lint and build passed with two
  pre-existing non-serious SwiftLint warnings; `mise run check` passed (622
  XCTest and 35 Swift Testing tests, SwiftLint, web, and Tauri checks), and
  `git diff --check` passed.

- 2026-08-31: comm-000562 addresses the renewed adversarial review. API-client
  issue, list, and revoke now transactionally require an enabled administrator
  or the unscoped local operator. Existing-library update/delete and
  grant/revoke mutations now require that same authority or an enabled owner
  membership, reporting foreign and missing libraries identically. Claimed
  auto-action dispatches carry their `(dispatchId, leaseToken)` into every
  provider-derived write transaction; lease loss cancels the active execution
  task and stale workers cannot apply tags, translation output/status, or chat
  persistence. Chat stream chunks are buffered until fenced completion. Added
  direct, ordinary-JWT, agent-JWT, administrator, unauthenticated, owner, and
  stale-lease regressions. Focused verification passed:
  `mise exec -- swift test --filter 'NoteUserTests|NoteLibraryMemberTests|AgentChatDispatchSecurityTests|CommandCLITests'`
  (43 XCTest and 19 Swift Testing tests), full `mise exec -- swift test --quiet`
  (625 XCTest and 36 Swift Testing tests), `mise run lint` (two pre-existing
  non-serious warnings), `mise run build`, `mise run check`, and
  `git diff --check`.

- 2026-08-31: comm-000564 closes the renewed Step 6 findings. API-client
  listing now authorizes and queries inside one database transaction; the
  disabled-administrator regression confirms listing fails after a standing
  change. Leased
  chat workers publish buffered chunks and terminal stream state only while
  their dispatch lease remains current; cancelled chat terminalization uses
  the same fenced service. Added a deterministic blocked-provider reclaim
  regression proving a superseded worker cannot publish chunks or terminal
  state and cannot replace the current worker's persisted reply. Focused
  security verification passed:
  `mise exec -- swift test --filter 'AgentChatDispatchSecurityTests|NoteUserTests|NoteLibraryMemberTests|CommandCLITests'`
  (45 XCTest and 19 Swift Testing tests). Full `mise exec -- swift test --quiet`
  verification passed (627 XCTest and 36 Swift Testing tests), as did
  `mise run lint` (two pre-existing non-serious warnings), `mise run build`,
  `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000566 closes the remaining Step 6 self-review races.
  API-client listing now has a deterministic separate-connection demotion
  attempt between administrator authorization and the global query; the
  transaction holds the write lock until the list commits. Leased chat streams
  register the claimed `(dispatchId, leaseToken)` with the stream hub before
  execution; chunks and `answered`, `failed`, and `cancelled` terminals are
  admitted only from that registered lease. Deterministic tests reclaim a
  lease after validation and before admission, and prove a superseded worker
  cannot publish a chunk or any terminal state. Focused
  `AgentChatDispatchSecurityTests|AgentReplyStreamHubTests|NoteUserTests|NoteLibraryMemberTests|CommandCLITests`
  verification passed (54 XCTest and 19 Swift Testing tests); full
  `mise exec -- swift test --quiet` passed (629 XCTest and 36 Swift Testing
  tests), as did `mise run lint` (two pre-existing non-serious warnings),
  `mise run build`, `mise run check`, and `git diff --check`.

- 2026-08-31: comm-000568 closes two follow-up lease-stream boundaries. A
  fenced cancellation that loses its database lease now fails closed instead
  of issuing an unleased terminal publication. A higher outbox attempt can
  reopen only a retryable failed stream generation; answered and cancelled
  streams remain terminal, and stale leases remain rejected. Deterministic
  regressions reclaim a cancellation lease after validation and verify a
  failed attempt can stream a successful retry. Focused
  `mise exec -- swift test --filter 'AgentChatDispatchSecurityTests|AgentReplyStreamHubTests'`
  passed (21 XCTest tests). Full `mise exec -- swift test --quiet` passed
  (631 XCTest and 36 Swift Testing tests); `mise run lint` passed with two
  pre-existing non-serious warnings, `mise run build` passed, and `mise run
  check` passed.

- 2026-08-31: comm-000570 binds terminal-delivery acknowledgements to the
  stream generation that produced the response. Retry cursors are monotonic:
  a cursor returned for a failed generation starts at the successful retry's
  first chunk, while a delayed failed-generation acknowledgement cannot make
  the answered retry eligible for eviction. Deterministic zero-retention
  coverage exercises both the stale-acknowledgement overlap and cursor
  continuity; focused and full verification evidence is recorded in
  `impl-plans/active/note-api-auth.md`.

- 2026-08-31: comm-000570 verification passed: focused
  `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests` ran 22 XCTest
  tests, and the two retry-generation regressions passed eight consecutive
  times. `mise exec -- swift test --quiet` passed (632 XCTest and 36 Swift
  Testing tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build` and `mise run check` passed.

- 2026-08-31: comm-000572 preserves a failed generation's cursor base when
  terminal retention evicts it before the higher-attempt retry begins. A fresh
  retry consumes the saved base, so polling it with the failed cursor returns
  its first chunk rather than skipping it. A deterministic pressured-retention
  regression evicts a failed stream with a chunk, starts a successful retry,
  and resumes from the failed cursor. Focused
  `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests` passed (23 XCTest
  tests); all three retry-generation regressions passed eight consecutive
  runs. `mise exec -- swift test --quiet` passed (633 XCTest and 36 Swift
  Testing tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build`, `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000574 replaces evicted failed-stream cursor tombstones
  with an opaque, JavaScript-safe generation-and-offset cursor. A cursor from
  an evicted failed generation automatically restarts a retry at chunk zero,
  with no per-turn retained state outside the bounded stream cache. Deterministic
  pressure coverage evicts 128 distinct failed streams, then retries the first
  turn with its original cursor and receives the retry chunk. Focused
  `mise exec -- swift test --filter 'AgentReplyStreamHubTests|AgentChatDispatchSecurityTests'`
  passed (24 XCTest tests), and the pressure regression passed eight consecutive
  runs. `mise exec -- swift test --quiet` passed (634 XCTest and 36 Swift
  Testing tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build`, `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000576 replaces the clock-polled deferred-response probe in
  `AgentReplyStreamHubTests` with an actor-owned registration handshake. The
  cancellation regression now cancels only after the terminal poll has
  deterministically registered its deferred response. Focused
  `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests` passed (24 XCTest
  tests), the cancellation regression passed 20 consecutive runs, full
  `mise exec -- swift test --quiet` passed (634 XCTest and 36 Swift Testing
  tests), and `mise run lint` (two pre-existing non-serious warnings),
  `mise run build`, and `mise run check` passed.

- 2026-08-31: comm-000581 closes both final response-construction
  authorization windows. Event batches are reauthorized after post-poll
  credential reauthentication before serialization, preserving the prepared
  cursor on operational failure. Terminal reply-stream delivery now performs
  its final turn and captured-library authorization inside the acknowledgement
  admission operation, after any acknowledgement wait and immediately before
  constructing the response. Deterministic regressions revoke library access
  during the second event authentication and during deferred terminal delivery;
  neither route returns protected metadata or chunks. Focused server security
  tests passed (49 XCTest tests); `mise run lint` passed with two pre-existing
  non-serious warnings, and `mise run check` passed (Swift, web, and Tauri
  verification).

- 2026-08-31: comm-000585 closes the final Step 7 control-plane transaction
  gaps. `libraries(forUser:)` now permits only the acting enabled account, an
  enabled administrator, or an unscoped operator; ordinary, agent-token, and
  unauthenticated principals receive an opaque missing-account result for
  foreign targets. Auto-action retry selection and stale-lease recovery each
  authorize and act in one immediate transaction, while account and admin
  listings do the same. Separate-connection demotion regressions cover all
  three transaction boundaries. Focused
  `mise exec -- swift test --filter 'NoteLibraryMemberTests|NoteUserTests|AutoActionTests'`
  passed (62 XCTest tests); `mise run lint` passed with two pre-existing
  non-serious warnings; `mise run check` passed (639 XCTest, 36 Swift Testing,
  156 Bun, 34 Vitest, web build, and Tauri checks).

- 2026-08-31: comm-000589 closes destination-library authorization for
  `moveNotebook`. The source notebook and destination library reach now resolve
  inside one immediate transaction; hidden and missing destinations both return
  the same missing-library result and leave the notebook in its original
  library. AppCore and ordinary-JWT CLI regressions cover protected-destination
  refusal and state preservation. `mise run check` passed (640 XCTest and 37
  Swift Testing tests, SwiftLint with two pre-existing non-serious warnings,
  web, and Tauri checks); `git diff --check` passed.

- 2026-08-31: comm-000594 closes tag-detail reach leaks and stale translation
  completion. `listTagComments` and tag-detail counts now apply current
  reachable-library predicates, including selected-library scope; AppCore and
  GraphQL tests cover unauthenticated protected-library access and revoked
  membership. Translation outputs persist a SHA-256 source-content hash,
  validate that hash in the output-write transaction, and require every
  current source version before completion; a deterministic source-body-edit
  regression proves the changed source is translated again. The scoped orphan
  file-read documentation now matches fail-closed behavior. Focused
  `mise exec -- swift test --filter 'NoteTagDetailTests|NoteGraphQLTagDetailTests|AITranslationTests'`
  passed (35 XCTest tests), the source-edit regression passed eight consecutive
  runs, `mise run lint` passed with two pre-existing non-serious warnings,
  `mise run build` passed, `mise run check` passed (643 XCTest and 37 Swift
  Testing tests, 156 Bun tests, 34 Vitest tests, web build, and Tauri checks),
  and `git diff --check` passed.

- 2026-08-31: comm-000596 closes stale translation-output retention after an
  edit that lands after the first output commits but before completion. The
  output-write transaction supersedes obsolete versions for the same source id,
  and snapshot/completion checks require exactly one output carrying the
  current source-content hash. The deterministic post-commit edit regression
  verifies the completed notebook contains only the updated translation. It
  passed eight consecutive runs; focused
  `NoteTagDetailTests|NoteGraphQLTagDetailTests|AITranslationTests` passed (36
  XCTest tests), `mise run lint` passed with two pre-existing non-serious
  warnings, `mise run build` passed, `mise run check` passed (644 XCTest and
  37 Swift Testing tests, web and Tauri checks), and `git diff --check` passed.

- 2026-08-31: comm-000600 closes two Step 7 mid-severity boundaries. A missing
  translation source at the post-provider output-write boundary now returns a
  stale snapshot outcome; the run refreshes and completes only against current
  remaining sources. `listAgentConversations` now applies current reachable
  library IDs in SQL before ordering and `LIMIT`, so revoked protected rows do
  not consume the page or make hydration fail. Deterministic provider-boundary
  deletion and revoked-membership list regressions passed. Focused
  `mise exec -- swift test --filter 'AITranslationTests|AgentChatLibraryBoundaryTests' --quiet`
  passed (26 XCTest tests); `mise run lint` passed with two pre-existing
  non-serious warnings; `mise run build` passed; `mise run check` passed (646
  XCTest and 37 Swift Testing tests, web and Tauri checks); and `git diff --check`
  passed.

- 2026-08-31: comm-000604 reconciles answered chat turns with recovered stream
  leases. Answered turns now persist their immutable provider-context library;
  a recovered current lease admits an `answered` terminal state to
  `AgentReplyStreamHub` without reinvoking the provider, while retaining the
  original library boundary after a later conversation move. A deterministic
  regression pauses the first worker after durable answer commit and before
  terminal admission, reclaims the actual outbox lease, runs the recovered
  dispatcher, and verifies `done=true`, `status=answered`, and exactly one
  provider invocation. Focused
  `mise exec -- swift test --filter 'AgentChatDispatchSecurityTests|AgentReplyStreamHubTests' --quiet`
  passed (25 XCTest tests); `mise run lint` passed with two pre-existing
  non-serious warnings; `mise run build` passed; `mise exec -- swift test --quiet`
  passed (647 XCTest and 37 Swift Testing tests); `mise run check` passed; and
  `git diff --check` passed.

- 2026-08-31: comm-000606 makes the legacy malformed-auto-action filter
  regression deterministic. Auto-action dispatches complete concurrently, so
  the test now requires exactly the two expected action IDs without coupling
  correctness to completion order. The focused regression passed 20
  consecutive runs; `AutoActionTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests`
  passed (50 XCTest tests); `mise run check` passed (647 XCTest, 37 Swift
  Testing, 156 Bun, and 34 Vitest tests; web build and Tauri checks); and
  `git diff --check` passed. SwiftLint retains two pre-existing non-serious
  warnings.

- 2026-08-31: comm-000610 reconciles TASK-M10 with the shipped tag-detail
  library scope. `listTagComments`, `taggedEntityCount`, and
  `findTagMemoNotebookId` now have documented reachable-library enforcement,
  with AppCore and GraphQL regression coverage; tag-detail scope is no longer
  listed as deferred. The remaining open items are sharing-era attribution and
  per-user long-term memory. Focused `NoteTagDetailTests|NoteGraphQLTagDetailTests`,
  `mise run lint`, `mise run check`, and `git diff --check` are recorded after
  this reconciliation.

- 2026-08-31: comm-000614 reopened TASK-408 after a woken nonterminal reply
  poll could lose its terminal tail while post-poll authentication was
  suspended. Every route-owned snapshot now holds a delivery obligation through
  final authorization; terminal completion unions those in-flight obligations,
  and a grace deadline that expires while one is pending restarts when the
  route accepts or rejects the nonterminal response. The deterministic route
  regression suspends second authentication after a chunk snapshot, finishes
  the stream, expires grace under retention pressure, then proves the
  successor cursor receives `done=true` and `status=answered`. TASK-408 is
  rechecked after focused `AgentReplyStreamHubTests|AgentReplyStreamRouteAuthorizationTests`
  (15 XCTest tests), eight consecutive regression runs, `mise run lint` (two
  pre-existing non-serious warnings), `mise run build`, `mise run check` (648
  XCTest, 37 Swift Testing, 156 Bun, and 34 Vitest tests; SwiftLint, web build,
  and Tauri checks), and `git diff --check`.

- 2026-08-31: comm-000616 makes the comm-000614 route regression deterministic.
  The hub now exposes an actor-owned test handshake that resumes only after
  grace expiry observed the active route delivery obligation. The regression
  waits for that boundary before applying retention pressure or releasing
  second authentication, then verifies the successor cursor receives the
  terminal tail. TASK-408 remains checked after focused stream tests, repeated
  regression runs, and the complete repository gate.

- 2026-08-31: comm-000621 closes three adversarial workflow-reliability gaps.
  Every queued chat, translation, and tag-extraction provider call now passes
  a final transactional lease-and-enabled-account admission check; deterministic
  pre-invocation disablement tests prove zero provider requests and durable
  cancellation. Active leased or polled reply streams survive capacity pressure
  until their terminal delivery can wake the waiting poll. Stale final-attempt
  leases now reconcile durable answered/completed work without a fourth provider
  call, or record a durable terminal cancellation when no terminal output exists.
  Focused `AgentChatDispatchSecurityTests|AgentReplyStreamHubTests|AutoActionTests|AITranslationTests`
  passed (71 XCTest tests); the six new interleaving regressions passed eight
  consecutive runs; `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build`, `mise run check` (651 XCTest and 37 Swift Testing
  tests, SwiftLint, web build, and Tauri checks), and `git diff --check` passed.

- 2026-08-31: comm-000623 restores bounded retained reply payloads without
  dropping current leased-stream or terminal-delivery metadata. The hub retains
  at most the configured number of chunk payloads, caps each payload at 256 KiB,
  and returns `resync=true` when a caller must refresh durable conversation
  state; active leases still finish and wake pending polls. Stale final-attempt
  recovery now classifies deleted durable targets as terminal cancellation and
  claims durable completions for exactly one provider-free reconciliation; a
  reconciliation failure is atomically cancelled rather than re-entering a
  fourth provider attempt. `AutoActionRecoveryTests` covers deleted targets and
  failed reconciliation; `AgentReplyStreamHubTests` covers maximum-plus-N hung
  leases, bounded payload bytes, resynchronization, and pending terminal wakeup.
  Focused tests and eight repeated regression runs passed; SwiftLint passed with
  two pre-existing non-serious warnings; `mise run build`, `mise run web:check`,
  `mise run check` (654 XCTest, 37 Swift Testing, 156 Bun, and 34 Vitest tests;
  web build and Tauri checks), and `git diff --check` passed.

- 2026-08-31: comm-000625 completes the reply-stream resynchronization
  remediation. `AgentReplyStreamHub` now tracks retained bytes in constant time
  and caps each stream at 256 chunks as well as 256 KiB, so empty and tiny ACP
  chunks cannot bypass payload memory or append-cost bounds. `MemoTab` clears
  incomplete transient output on `resync=true`, reloads durable conversation
  state, and waits for terminal persistence rather than displaying a stitched
  prefix and suffix. `AgentReplyStreamHubTests` passed across eight repeated
  runs; `mise run build`, `mise run web:check` (156 Bun, 35 Vitest), and
  `mise run check` (655 XCTest, 37 Swift Testing, SwiftLint, web, and Tauri)
  passed; `git diff --check` passed.

- 2026-08-31: comm-000630 closes three reply and translation reliability
  findings. Leased chat chunks now pass through a bounded, ordered relay to
  the lease-fenced stream hub while generation is still in progress; a
  deterministic live-poll regression observes the first chunk before durable
  answer completion. The relay accepts at most 256 chunks and 256 KiB, and the
  ACP process collector enforces the same stdout cap before retaining data.
  Translation reconciliation now has round, provider-call, and elapsed-time
  budgets; non-converging source churn fails the current dispatch so its
  durable outbox retry budget applies. Focused
  `AgentGatewayCLIInvokerTests|AITranslationTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests`
  passed (61 XCTest tests), and `mise run check` passed (659 XCTest and 37
  Swift Testing tests; SwiftLint with two pre-existing non-serious warnings,
  156 Bun tests, 35 Vitest tests, web build, and Tauri checks).

- 2026-08-31: comm-000632 corrects the translation elapsed-time boundary.
  `AITranslationService` now checks the five-minute reconciliation deadline
  before each provider call, after each call, and before completion, so a slow
  first round cannot begin additional provider invocations after expiry. A
  deterministic injected-clock regression advances time during the first call,
  proves only that call occurs, and verifies retryable failed status. Focused
  `AgentGatewayCLIInvokerTests|AITranslationTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests`
  passed (62 XCTest tests), and the elapsed-budget regression passed eight
  consecutive runs; `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run check` passed (660 XCTest and 37 Swift Testing tests,
  SwiftLint, web, and Tauri checks); and `git diff --check` passed.

- 2026-08-31: comm-000636 preserves a tag memo's existing library when its
  final tagged source is removed. A memo rehomes only when exactly one current
  reachable source library remains; mixed sources continue to fail. AppCore
  and GraphQL regressions create a protected memo, remove its final source
  tag, ensure it through the ordinary default-user scope, and verify it stays
  inaccessible to unauthenticated readers. TASK-M06 remains complete only
  after this regression and repository verification pass. Focused
  `NoteTagDetailTests|NoteGraphQLTagDetailTests|AgentGatewayCLIInvokerTests|AITranslationTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests`
  passed (83 XCTest tests); the two new regressions passed eight consecutive
  runs; `mise run lint` passed with two pre-existing non-serious warnings;
  `mise run build` passed; and `mise run check` passed (662 XCTest and 37 Swift Testing tests, SwiftLint,
  web, and Tauri checks).

- 2026-08-31: comm-000641 closes final recovery and gateway-liveness review
  findings. Provider-free final reconciliation now preserves already answered
  chat turns and completed translation notebooks before disabled-principal
  cancellation logic, acknowledging the outbox without provider invocation or
  overwriting durable success. `AgentGatewayCLIInvoker` now has configurable
  deadline and grace settings, cancellation-triggered pipe closure, SIGTERM,
  and bounded SIGKILL escalation; closing output pipes also prevents
  descendant-held descriptors from hanging collection. New regressions cover
  disabled-after-commit chat and translation recovery, a gateway that never
  reads stdin, and one that ignores SIGTERM. Focused
  `mise exec -- swift test --filter 'AgentGatewayCLIInvokerTests|AutoActionRecoveryTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests' --quiet`
  passed (48 XCTest tests); the two gateway termination regressions passed
  eight consecutive runs; `mise run lint` passed with two pre-existing
  non-serious warnings; `mise run build`, `mise run check` (666 XCTest, 37
  Swift Testing, 156 Bun, and 35 Vitest tests; SwiftLint, web build, and Tauri
  checks), and `git diff --check` passed after this progress-log update.

- 2026-08-31: comm-000643 closes the Step 6 gateway-process self-review
  findings. Gateway launch now uses `posix_spawn` with an isolated process
  group, so timeout and cancellation send SIGTERM and SIGKILL to the gateway
  and its provider descendants. Linux stdin writing blocks and consumes
  SIGPIPE on its detached writer thread; macOS retains `F_SETNOSIGPIPE`.
  Regressions cover blocked-writer cancellation and force-killing a recorded
  descendant PID. The focused 50-test Swift selection and eight repeated
  gateway regressions passed; Linux POSIX interfaces typechecked; `mise run
  lint` passed with two pre-existing non-serious warnings; and `mise run
  check` passed (668 XCTest, 37 Swift Testing, 156 Bun, and 35 Vitest tests;
  SwiftLint, web build, and Tauri checks), along with `git diff --check`.

- 2026-08-31: comm-000645 completes the remaining gateway descendant-lifecycle
  contract. SIGKILL now tests isolated process-group liveness instead of the
  direct gateway's `waitpid` state and retains its terminator through the
  grace escalation. The invocation deadline remains active through group
  cleanup and output finalization; pipe collection uses a nonblocking drain,
  so a descendant retaining stdout or stderr cannot stall completion. New
  regressions cover a SIGTERM-exited parent with a SIGTERM-ignoring recorded
  child and a normally exited parent whose descendant holds output open. The
  complete gateway test class passed (17 XCTest tests), and both new
  regressions passed eight consecutive runs. `mise run lint` passed with two
  pre-existing non-serious warnings, and `mise run check` passed (669 XCTest,
  37 Swift Testing, 156 Bun, and 35 Vitest tests; SwiftLint, web build, and
  Tauri checks).

- 2026-08-31: comm-000647 closes the post-exit cancellation lifecycle gap.
  Descendant cleanup is now cancellation-observed through output finalization,
  so cancellation after the gateway leader exits returns `CancellationError`
  only after the process group has been cleaned up. Process-group polling uses
  a cancellation-independent paced dispatch wait rather than a cancelled
  `Task.sleep` busy spin. The new post-exit cancellation regression passed
  eight consecutive runs; `mise exec -- swift test --filter
  AgentGatewayCLIInvokerTests --quiet` passed (18 XCTest tests); `mise run
  lint` passed with two pre-existing non-serious warnings; `mise run build`
  passed; and `mise run check` passed (670 XCTest, 37 Swift Testing, 156 Bun,
  and 35 Vitest tests;
  SwiftLint, web build, and Tauri checks).

- 2026-08-31: comm-000649 completes the deterministic verification requested
  after comm-000647. The gateway test now uses an injected cleanup-poll pacer:
  its first suspended poll can occur only after the direct child completion
  waiter has returned, so cancellation is deterministically post-child. While
  cancelled, the test proves the scheduler remains responsive and that no
  additional process-group poll can occur until the paced waiter is released,
  ruling out a busy-spin cleanup loop. The focused gateway class passed (18
  XCTest tests), the new regression passed eight consecutive runs, `mise run
  lint` passed with two pre-existing non-serious warnings, `mise run build`
  passed, and `mise run check` passed (670 XCTest, 37 Swift Testing, 156 Bun,
  and 35 Vitest tests; SwiftLint, web build, and Tauri checks).

- 2026-08-31: comm-000654 closes the renewed adversarial review findings.
  Served `agent-gateway` invocations now reject tool-capable coding vendors,
  require an explicit selected credential, and run tool-free API vendors in a
  fresh macOS filesystem sandbox with an allowlisted environment. The reply
  stream now replaces all payload, authorization, cursor, and delivery state
  when a newer lease takes over a nonterminal attempt, forcing client resync
  instead of concatenating stale output. Gateway sentinel-secret/read/write
  and nonterminal lease-takeover regressions passed; focused security suites,
  SwiftLint (two pre-existing non-serious warnings), and `mise run check`
  passed. TASK-M06 status now reflects the completed review evidence.

- 2026-08-31: comm-000656 follow-up narrows the served gateway sandbox to the
  exact configured executable rather than its parent directory, preflights
  served vendor/credential/platform requirements before reconciliation enables
  auto-actions, and suppresses served ACP/stderr diagnostics before they can
  enter durable chat or translation state. Regressions cover a sibling secret,
  rejected and credential-less served factory configurations, and credential
  sentinel diagnostics, including model-catalog failures. Focused gateway,
  reconciliation, chat, translation, and stream suites passed (97 XCTest
  tests); `mise run lint` passed with two pre-existing non-serious warnings;
  `mise exec -- swift test --quiet` passed (678 XCTest and 37 Swift Testing
  tests); and `mise run check` passed (Swift, SwiftLint, web, and Tauri
  checks).

- 2026-08-31: comm-000658 completes the remaining served gateway hardening.
  Served preflight rejects invalid and sandbox-reserved credential environment
  names before isolated-environment construction, preventing runtime-key
  replacement and duplicate-key termination. A removed configured binary and
  every other served setup failure now produce fixed safe diagnostics before
  durable chat or translation state is written. `HOME`/`PATH` collision,
  reconciliation, invocation, and post-preflight binary-removal regressions
  passed alongside the focused gateway, reconciliation, chat, and translation
  suite (80 XCTest tests); SwiftLint passed with two pre-existing non-serious
  warnings and `mise run check` passed after this revision.

- 2026-08-31: comm-000662 corrects AI9 translation reconciliation accounting.
  Initial stable source processing no longer consumes the 128-call or
  five-minute churn budgets; those limits begin only after completion detects a
  changed source set, preserving bounded sustained churn without exhausting a
  large stable notebook's three durable attempts. Direct and queued 129-note
  regressions verify completion and first-attempt dispatch status, while the
  elapsed-budget regression now exercises a genuine changed-source
  reconciliation. The AI9 contract documents `cancelled` as terminal and
  non-resumable during recovery. `AITranslationTests` passed (22 XCTest tests),
  the focused adjacent security suite passed (81 XCTest tests), SwiftLint
  retained only two pre-existing non-serious warnings, and `mise run check`
  passed (Swift, SwiftLint, web, and Tauri checks).

- 2026-08-31: comm-000666 remediates the renewed Step 7 replay, event-client,
  and control-plane findings. Idempotent chat replay now requires a
  server-managed agent-conversation notebook and a genuine chat-turn state
  before returning a prior turn; it still returns committed replays after a
  note subject is deleted. Event subscriptions commit their cursor only after
  `onConnect` and every `onEvent` callback complete, so a callback failure
  retries the same retained batch. Global auto-action and dispatch-attempt
  listings now hold administrator authorization and selection in one immediate
  transaction. GraphQL regressions cover ordinary notebooks, forged notes, and
  forged conversations; web coverage proves callback-failure replay; and
  deterministic separate-connection demotion coverage protects both listings.
  Focused `AgentChatGraphQLTests|AutoActionTests` passed (51 XCTest tests),
  focused `events.test.ts` passed (8 Bun tests), and final `mise run check`
  passed with 685 XCTest, 37 Swift Testing, 157 Bun, and 35 Vitest tests;
  SwiftLint retained only two pre-existing non-serious warnings.

- 2026-08-31: comm-000668 closes the remaining public forged-turn replay
  path. GraphQL public note creation now rejects the server-managed
  `kaibaChat` metadata namespace, so a caller cannot supply pending status,
  user markdown, and an idempotency key inside a genuine conversation.
  The GraphQL replay regression supplies that complete forged shape, verifies
  rejection, and verifies the subsequent genuine turn remains replayable.
  `AgentChatGraphQLTests` passed (23 XCTest tests), SwiftLint retained only
  two pre-existing non-serious warnings, and `mise run check` passed.

- 2026-08-31: comm-000673 adversarial remediation is in progress. Authorized
  idempotent GraphQL replays now return before model-catalog discovery, and
  catalog discovery is cache-backed and single-flight. Event cursors and reply
  streams now reject excess waiters with 429, reply streams reject non-chat
  note identifiers, and the local HTTP listener caps accepted connections.
  Translation continuation and shared provider-execution admission remain
  open; this entry intentionally does not claim TASK completion. Focused
  `AgentChatGraphQLTests|NoteChangeFeedOverflowTests|AgentReplyStreamHubTests`
  passed (43 XCTest tests), as did `mise exec -- swift build`, SwiftLint with
  two pre-existing warnings, and `git diff --check`.

- 2026-08-31: comm-000675 completes the remaining availability and provider
  cost-control remediation. A shared `AgentExecutionAdmission` now applies
  global and per-principal nonblocking backpressure to queued provider work
  and model-catalog subprocess discovery; catalog single-flight and cache hits
  remain admission-free. Translation dispatches persist a continuation source
  and execute at most 128 source/provider calls per durable dispatch, with
  elapsed-time checks before and after every provider call; deferred chunks
  are returned to the pending outbox without consuming retry attempts. Direct
  pressure regressions cover event waiters, reply waiters, non-chat stream
  turns, the exact 256-connection limit, global/principal execution admission,
  catalog overload, and a 129-source durable translation continuation.

- 2026-08-31: comm-000677 bounds translation source and output hydration with
  durable cursor/keyset pages of at most 128 sources, and replaces the HTTP
  capacity predicate-only test with 256 simultaneous live connections, a 429
  rejection for connection 257, and verified capacity release. The bounded
  translation and 100-test focused matrix passed; the connection test passed
  three consecutive runs; SwiftLint retained only two pre-existing warnings.
  The required full repository gate is intentionally not marked complete: its
  complete-suite run repeatedly stalls at
  `AgentGatewayCLIInvokerTests/testInvokerForceKillsGatewayThatIgnoresSIGTERM`;
  the standalone gateway class passes.

- 2026-08-31: comm-000679 fixes the bounded translation completion and source
  snapshot follow-up. Cursor completion retains the prior keyset tail when an
  exact 128-source page is followed by an empty page, so exact 128- and
  256-source direct and queued translations complete. Translation state now
  captures a durable source revision rather than a wall-clock timestamp;
  deterministic post-output edit and deletion regressions restore the original
  timestamp and still restart or prune safely. The
  SIGTERM-ignore gateway regression now isolates the leader-only escalation
  case; focused translation tests (28 XCTest), the gateway class (25 XCTest),
  eight repeated force-kill runs, and SwiftLint passed. Complete repository
  verification remains in progress before renewed Step 7 review.

- 2026-08-31: comm-000679 complete verification passed. The full
  `mise run check` gate completed with 698 XCTest and 37 Swift Testing tests,
  SwiftLint (two pre-existing non-serious warnings), web checks/build, and
  Tauri checks. A route-authorization fixture was aligned with the existing
  non-chat stream rejection by creating genuine scoped conversation turns;
  both deterministic route tests pass instead of waiting forever for an
  ineligible ordinary note to register a stream poll.

- 2026-08-31: comm-000681 closes the remaining translation source-revision
  gap. Completing an agent-chat turn now records the changed body as a
  non-undoable AI note action in the same database transaction, advancing the
  durable source revision used by translation completion. A deterministic
  post-output regression commits an assistant reply while restoring the source
  notebook timestamp, then verifies translation retranslates the answered
  turn rather than completing stale output. Focused translation, pagination,
  chat, and library-boundary verification passed; complete repository-gate
  verification is recorded with this Step 6 remediation.

- 2026-08-31: comm-000685 corrects AI9 direct-pagination reconciliation
  accounting. Unchanged keyset pages no longer consume the eight-round source
  churn budget; only an observed source revision change or cursor reset does.
  A direct 1,024-source regression covers exactly eight full 128-source pages
  followed by the empty completion page, proving stable synchronous translation
  completes at the round-by-provider boundary. AI9 now documents durable
  128-source pagination, stable direct continuation, and revision-only round
  charging. `AITranslationTests|AITranslationPaginationTests` passed 30
  XCTest tests; SwiftLint retained two pre-existing non-serious warnings; and
  `mise run check` passed 700 XCTest and 37 Swift Testing tests plus web and
  Tauri checks.

- 2026-08-31: comm-000687 replaces translation's prunable action-log lookup
  with a non-prunable per-notebook revision written in the same
  transaction as each notebook action. A deterministic `history.maxEntries =
  10` regression mutates an already translated source, emits enough later
  outputs to prune that mutation's history row, and verifies the stale source
  is translated again before completion.

- 2026-08-31: comm-000692 adversarial remediation separates gateway leader
  cleanup from post-reap descendant cleanup. Once `waitpid` has reaped the
  leader, cleanup only observes and signals the surviving process group and
  never retains a delayed direct-PID escalation. The local HTTP server also
  applies resettable incomplete-request deadlines, cancelling stalled header
  or body reads so partial unauthenticated requests release the 256-connection
  capacity. Deterministic regressions cover no post-reap termination signal
  after a normal gateway exit and timeout-driven recovery from 256 incomplete
  socket requests. Focused gateway/lifecycle/capacity coverage passed (28
  XCTest tests); SwiftLint reported only two pre-existing non-serious warnings;
  and `mise run check` passed.

- 2026-08-31: comm-000694 Step 6 remediation closes the post-`waitpid`
  publication boundary and the slow-progress HTTP capacity boundary. Gateway
  cleanup now publishes shared reap state before completion, never signals a
  positive gateway PID, and only performs post-reap process-group cleanup when
  inherited output descriptors prove a helper remains. The incomplete-request
  deadline is now absolute rather than reset by every partial read. Lifecycle
  coverage pauses completion publication after reaping, fires the timeout, and
  proves no signal is emitted; capacity coverage sends additional partial
  request bytes across all 256 occupied connections, then proves the original
  deadline releases capacity. Focused gateway/lifecycle/capacity coverage
  passed 29 XCTest tests; the complete Swift suite passed 704 XCTest and 37
  Swift Testing tests; and `mise run check` passed with SwiftLint reporting
  only two pre-existing non-serious warnings.

- 2026-08-31: comm-000696 closes the remaining waitpid-to-reap-publication
  process-group race. Direct-child polling, reap-state publication, and every
  pre-reap SIGTERM/SIGKILL decision now use one synchronized lifecycle
  authority, so a callback that races `waitpid` either observes a still-live
  leader before signaling or observes the reaped leader and emits no signal.
  The deterministic lifecycle regression pauses immediately after `waitpid`
  returns while lifecycle authority remains held, fires the timeout and grace
  escalation, then verifies that neither signal is issued. The preserved
  absolute incomplete-request deadline remains covered by the capacity suite.
  Focused gateway/lifecycle/capacity coverage passed 30 XCTest tests; the
  complete Swift suite and `mise run check` passed 705 XCTest and 37 Swift
  Testing tests, 157 Bun tests, 35 Vitest tests, SwiftLint with two
  pre-existing non-serious warnings, web build, and Tauri checks.

- 2026-08-31: comm-000699 corrects the lifecycle regression so it exercises
  the already-scheduled grace-period SIGKILL callback. After timeout admits
  the initial SIGTERM, the test deterministically terminates its fixture,
  pauses direct-child reaping before publication, holds the scheduled SIGKILL
  callback before lifecycle-lock admission, then releases both gates and
  verifies that only the initial SIGTERM was observed. This closes the former
  test-integrity gap where a fixture that exited before timeout never
  scheduled escalation. Focused gateway/lifecycle/capacity coverage passed 30
  XCTest tests and the corrected lifecycle regression passed eight consecutive
  runs. SwiftLint reported only two pre-existing non-serious warnings. The
  post-revision `mise run check` gate stalled without failure output and was
  interrupted after 654 seconds; renewed complete-gate evidence remains
  required before independent review.

- 2026-08-31: comm-000701 corrects the grace-escalation fixture so the gateway
  leader stays alive until the real timeout SIGTERM, records that signal in a
  deterministic handler, and exits from that handler before `waitpid` pauses
  reap publication. The scheduled SIGKILL callback is then held at its
  production hook and released only after the reaping gate, proving it emits
  no second signal. Gateway spawning now explicitly restores and unmasks
  SIGTERM so child lifecycle behavior cannot inherit a suppressing test-host
  disposition. Focused gateway/lifecycle/capacity coverage passed 30 XCTest
  tests, the corrected regression passed eight consecutive runs, and the
  clean `mise run check` gate passed 705 XCTest and 37 Swift Testing tests,
  157 Bun tests, 35 Vitest tests, SwiftLint with two pre-existing non-serious
  warnings, web build, and Tauri checks.

- 2026-08-31: comm-000703 makes the terminal-delivery cancellation regression
  deterministic under complete-suite scheduler load. The test's existing
  actor-owned deferred-response registration still establishes that terminal
  state exists before cancellation; its ordinary poll deadline is now a
  60-second non-interfering safety bound rather than a two-second competing
  event. The same complete-gate run exposed a fixed-delay lifecycle test; its
  readiness now waits for the post-reap timeout attempt rather than elapsed
  time. Twenty repeated stream runs, eight repeated lifecycle runs, focused
  combined tests (22 XCTest tests), SwiftLint with two pre-existing
  non-serious warnings, and `mise run check` passed (705 XCTest, 37 Swift
  Testing, 157 Bun, and 35 Vitest tests; web build and Tauri checks).

- 2026-08-31: comm-000707 preserves the bounded AI9 durable-retry contract
  for queued source churn: unchanged keyset pagination remains deferred,
  while a reconciliation-required page consumes one outbox attempt. Gateway
  post-reap cleanup is no longer conditioned on inherited stdout/stderr EOF,
  so an ignoring descendant that closes those descriptors is still terminated
  through the group-only cleanup path; normal-exit and pre-reap lifecycle
  guards continue to prohibit delayed signals to a reused leader identity.
  Focused translation/gateway coverage passed 60 XCTest tests and the
  closed-descriptor descendant regression passed eight consecutive isolated
  runs; `mise run lint` retained two pre-existing non-serious warnings; and
  `mise run check` passed 707 XCTest, 37 Swift Testing, 157 Bun, and 35 Vitest
  tests plus web build and Tauri checks. Renewed review remains required.

- 2026-08-31: Step 6 revision resolves
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-finding-1`.
  Gateway invocations now create a dedicated `sleep` witness as the process
  group leader, join the gateway to that group, and retain the witness as an
  unreaped direct child through SIGTERM and final SIGKILL. This makes every
  post-reap group signal depend on a non-reusable ownership identity rather
  than the reaped gateway PID/PGID. Deterministic lifecycle regressions cover
  normal cleanup, timeout after reaping, scheduled escalation, and an ignoring
  descendant that closes inherited descriptors. Focused translation/token/
  gateway/lifecycle/capacity verification passed 90 XCTest tests; `mise run
  lint` passed with three non-serious warnings; `mise run build`, `mise run
  check` (707 XCTest, 37 Swift Testing, 157 Bun, and 35 Vitest tests), and
  `git diff --check` passed.

- 2026-08-31: Step 6 follow-up resolves
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-finding-2`.
  Cleanup retains the process-group witness while polling for SIGTERM exit,
  sends final SIGKILL only if the witnessed group remains live, waits through
  the bounded post-kill observation interval, and reaps the witness only
  afterward. This restores the comm-000647 contract: a cancellation after the
  gateway leader exits does not complete while its descendant remains alive.
  An un-injected production-path regression covers that sequence. Focused
  translation/token/gateway/lifecycle/capacity verification passed 91 XCTest
  tests; `mise run lint` passed with three non-serious warnings; `mise run
  build`, `mise run check` (708 XCTest, 37 Swift Testing, 157 Bun, and 35
  Vitest tests), and `git diff --check` passed.

- 2026-08-31: Step 6 revision resolves comm-000715's follow-up to
  authoritative prior finding
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-attempt-1-finding-1`.
  Cleanup now enumerates group members while excluding the direct-child
  ownership witness, so a descendant-free post-reap exit does not wait through
  grace or receive SIGKILL. After SIGKILL, the production path waits until all
  descendants disappear before reaping the witness and returning cancellation.
  `mise exec -- swift test --filter
  'AgentGatewayPostExitCancellationTests|AgentGatewayCLIInvokerTests|AgentGatewayCLIInvokerLifecycleTests' --quiet`
  passed 30 XCTest tests, including the new no-grace/no-SIGKILL production
  regression and post-exit cancellation disappearance proof.

- 2026-08-31: Step 6 self-review follow-up resolves
  `codex-design-and-implement-review-loop-session-51-step6-implement-self-review-attempt-1-finding-1`
  and `codex-design-and-implement-review-loop-session-51-step6-implement-self-review-attempt-1-finding-2`.
  Cleanup distinguishes empty, live, zombie-only, and unavailable descendant
  states. It waits for zombie disappearance without SIGKILL and fails closed
  while retrying unavailable membership inspection; Darwin retries `sysctl`
  snapshot races. Deterministic lifecycle regressions cover both states.
  `mise exec -- swift test --filter
  'AgentGatewayPostExitCancellationTests|AgentGatewayCLIInvokerTests|AgentGatewayCLIInvokerLifecycleTests' --quiet`
  passed 32 XCTest tests; `mise run build` and `mise run lint` (three
  non-serious warnings) passed; `git diff --check` passed.
