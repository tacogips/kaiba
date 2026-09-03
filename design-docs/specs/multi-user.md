# Multi-User Note Store

**Status**: Implemented across GraphQL, file-byte, event-stream, reply-stream,
and tag-grounded chat boundaries
**Related**: `design-docs/specs/note-api-auth.md`, `design-docs/specs/kaiba-note.md`

## Purpose

Let one kaiba store serve several people, each seeing their own notebooks,
while an unauthenticated host keeps working exactly as it does today by acting
as a single default user.

## Current State

The identity foundation has shipped: the `users` table and seeded default
admin, notebook ownership and attribution columns, per-user API clients, JWT
issuance and verification, catalog scoping, CLI `--jwt` / `--jwt-env`, and
per-request GraphQL service scoping. The schema is fresh-schema-only: a store
at any other `NoteStoreSchema.currentVersion` is rejected with
`unsupportedLegacyVersion` or `unsupportedFutureVersion`, and there is no
migration path.

The delivered boundary is narrower but security-critical: by-id and bulk reads
carry ownership checks, file-byte delivery uses GraphQL's default-user fallback,
the API exposes notebook ownership and attribution, and authenticated callers
can mint short-lived agent tokens only for themselves. Safety cancellations of
queued AI work are a distinct terminal dispatch status (`cancelled`) so they
are never mistaken for successful provider work.

## Design

### Users

```sql
CREATE TABLE users (
  user_id TEXT PRIMARY KEY,
  email TEXT UNIQUE,
  display_name TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
  is_admin INTEGER NOT NULL DEFAULT 0 CHECK (is_admin IN (0,1)),
  created_at TEXT NOT NULL,
  disabled_at TEXT
) STRICT
```

- `email` is optional, because the default user has no address, and unique on a
  normalized (lowercased, trimmed) form when present. SQLite treats NULLs as
  distinct in UNIQUE constraints, so a plain UNIQUE already allows any number
  of email-less accounts.
- At most one row may carry `is_default = 1`, enforced by a partial unique
  index rather than by convention.
- A user is never deleted, only disabled. Notebooks outlive the account that
  made them, and a foreign key from `notebooks` would otherwise strand them.

### The default user

The default user is created **when the store is first created**, in the same
first-run path that seeds tag classes and auto-actions
(`NoteStoreSchema.prepare`). Its id is the stable literal `user-default` so
every process agrees on it without a lookup by flag.

It is a real row, not a null case: every notebook has a real owner, so no query
needs an "owner is null means everyone" branch, which is the usual source of
accidental cross-user reads.

An unauthenticated request acts as this user. That keeps
`--allow-unauthenticated` behaving exactly as it does today: one principal, one
set of notebooks, no login.

### The admin role

The default user is seeded as an **admin**, so a store always has at least one
even when nothing is authenticated. An admin reaches every library, including
the ones marked `auth_required` and the ones it holds no `library_members` row
for (`design-docs/specs/library.md`). It is not a second ownership rule:
notebook catalogs stay scoped to their owner, so an admin does not read another
account's notebooks — the role widens *library* reach, nothing else.

```
kaiba user add --email a@example.com --admin
kaiba user grant-admin  <user-id>
kaiba user revoke-admin <user-id>
```

A store may never end up with no enabled admin: demoting or disabling the last
one is refused, and the caller is told to promote someone first. The role is
read per request rather than cached on the service value, so a demotion takes
effect on the next call instead of at the next process start.

An unauthenticated *served* request acts as this admin account for ownership
and attribution, but the transport's `isUnauthenticatedRequest` marker still
caps it at the open libraries. Opening a port and handing that port every
library are two decisions, and `kaiba serve --allow-unauthenticated --as-admin`
is the second one, made explicitly. Serve refuses the flag without
`--allow-unauthenticated`, and refuses to start when the account it would bind
to is no longer an enabled admin.

### Ownership

Ownership lives on the notebook:

```sql
ALTER TABLE notebooks ADD COLUMN owner_user_id TEXT NOT NULL REFERENCES users(user_id)
```

Notes, files, comments, and links reach their owner through their notebook, so
they carry no owner column of their own and cannot drift out of agreement with
it. Tags and tag classes stay global: the ontology is shared vocabulary, and a
per-user tag namespace would fragment folders and system tags for no gain at
this size.

`api_clients` gains `user_id`, so a CLI key acts as its user rather than as an
anonymous whole-store credential.

### Attribution

`notebooks` and `notes` both carry `created_by` and `updated_by` referencing
`users(user_id)`, so a shared store can answer "who wrote this" without
replaying the change feed. Every insert and every update maintains them.

Where a service value is in hand the columns take the **acting** user
(`writeOwnerUserId()`, which falls back to the default user when unscoped).
The raw-SQL internal paths — long-term memory, agent chat — instead derive them
from the row's notebook owner, which works from free functions that write notes
without any plumbing. Under this design the two are the same value: one owner
per notebook, no sharing. **When notebook sharing arrives, that must change**:
those sites then have to carry the request's acting user, and deriving them
from the owner would silently credit the wrong person.

### Acting user

`NoteService` is a struct over a shared driver, so the acting user is a stored
property with a `scoped(to:)` copy rather than a parameter on every method:

- `actingUserId == nil` means unscoped — the CLI's default, and how internal
  bootstrap paths write.
- `actingUserId == someId` scopes writes (new notebooks take that owner) and
  reads (notebook queries filter on it).

The server resolves the acting user once per request from the authenticated
principal, and unauthenticated requests resolve to the default user. The CLI
resolves it from `--jwt` (see below); without one it stays unscoped.

### The CLI acts as a user

`kaiba` is a separate process that opens the store directly, so it needs a
credential of its own:

```
kaiba --jwt <token> add --notebook <id> --body "..."
kaiba --jwt-env KAIBA_TOKEN list
```

`--jwt-env` names an environment variable instead, keeping the token out of the
process table and the shell history. Passing both is refused rather than
silently preferring one. `kaiba auth whoami` reports the resolved account, and
`kaiba auth token issue --user <id> [--ttl-minutes N]` mints one.

Tokens are HS256 JWTs (`sub`, `iss`, `iat`, `exp`, `jti`) signed with a key
generated on first use and stored in the store's `app_settings`. The key lives
in the store because the processes that need it are exactly the processes that
already open the store: nothing extra to distribute, and no key sitting in a
dotfile to be copied. Verification checks the signature, the issuer, and expiry
with a small clock-skew allowance, then re-reads the account — a token for a
user who has since been disabled is refused even though it is still
well-formed.

### The agent hand-off

An agent asked to write a note must write it as the person who asked, not as
the machine:

1. The browser calls the server with its session credential.
2. The server mints a short-lived token for the signed-in user
   (`issueAuthToken`) and passes it to the agent along with the task.
3. The agent runs `kaiba --jwt <token> ...`.
4. The note is owned by, and attributed to, that user.

The token is short-lived and scoped to one account, so an agent that leaks or
over-uses it can only act as the user who invoked it, and only for as long as
the token lives. The agent never sees a password, a session cookie, or the
signing key.

### Ownership enforcement

The catalog filters by owner, but a caller who already holds an id must not be
able to step around that filter. Enforcement therefore sits where library reach
already sits (`Sources/AppCore/NoteService+LibraryEnforcement.swift`), not in a
second parallel layer: that file already shadows the unguarded row readers
(`loadNote`, `loadNotebook`, `loadWritableNote`, `loadWritableNotebook`,
`requireReachableFile`) under the `require*` names every service path calls, so
one predicate added there reaches all of them at once. Two guards on the same
chokepoint also cannot drift apart, which a second layer eventually would.

The rule has three shapes, matching the three shapes of read:

- **By id.** `require*` resolves the row's notebook and refuses when its
  `owner_user_id` is not the acting user. Notes, comments, links, and file
  attachments reach their notebook through their note, so they are covered by
  the same check rather than by one of their own — the same reason they carry
  no owner column.

  This holds **only for the paths that actually call `require*`**, and not
  every one does. The free functions below the service layer call the
  unguarded `load*` readers directly, and one of them is reached from a public
  entry point with no guard above it: `linkNotesInDatabase`
  (`NoteService+Relations.swift:481-482`) validates both link endpoints with
  `loadNote`, and the public `NoteService.linkNotes` (`:5`, exposed on GraphQL
  at `NoteGraphQLService.swift:394`) delegates to it without a `require*` of
  its own. The conversation-turn writer does the same for its source notes
  (`:353`, and `:358` via `requireNotes`, a hydration helper that carries no
  guard). This is already a live *library* enforcement bypass on those same
  lines, independent of this work.

  The rule, therefore: **a by-id read or write reached from a public entry
  point must pass through `require*` in that entry point.** A free helper
  below it may keep `load*` for existence, but it must never be the only
  guard. `listLinks` (`:25`), `proposeLinks` (`:47`) and `graphNeighbors`
  (`NoteGraph.swift:53`) already do this, which is exactly why the bypass is
  easy to miss — the surrounding code looks guarded.

  **Which `require*`** follows from what the path does to the row, not from
  whether the call is nominally a write: the read-level `requireNote` /
  `requireNotebook` when the row is only *referenced*, and the writable
  variants only when that row itself is modified. A link is the case that
  makes the distinction matter. Creating one inserts into `note_links` and
  changes neither note, and the endpoints are validated today with the
  read-level `loadNote`, so **`linkNotes` requires both endpoints with
  `requireNote`** — and the conversation-turn writer requires its source notes
  the same way. Reaching for `requireWritableNote` because "linking is a
  write" would refuse a read-only endpoint, and read-only endpoints are
  ordinary here: `NotePageDraft.readOnly` defaults to true, so imported
  document pages are read-only, and agent chat links a turn to exactly such a
  page with `source-citation`. Ownership is the only thing this work adds to
  these paths; the read-only semantics must come through unchanged.
- **Bulk reads.** A list, a search, or a cross-notebook aggregate carries an
  owner predicate in its SQL, next to the library predicate it already carries
  (`notebooks.owner_user_id = ?`). Dropping rows after the query would hand a
  caller fewer hits than the page it asked for, which is the same argument the
  library scope already makes. This covers `listNotes`, `searchNotes` (through
  `NoteSearchScope`, alongside `reachableLibraryIds`), and every graph
  traversal expansion and exit filter. A graph path is returned only when each
  node on it is reachable, so an unreachable intermediate cannot influence
  ranking or leak through `pathNoteIds`.

  The tag detail surface is **not one thing**, and its three members get three
  different answers, so naming it as a unit would hide two of them:
  `listTagComments` and `tagDetail`'s two `taggedEntityCount` calls take the
  owner predicate; `tagDetail.memoNotebookId` is resolved per owner, at the
  lookup rather than by a predicate here (see "The tag memo notebook is
  resolved per owner" below); and `tagContextMarkdown` applies the same owner,
  reachable-library, and internal-memory predicates before its 50-note limit.
- **Attachment bytes.** The predicate goes into `requireReachableFile`, whose
  referencing-notebook query is the only path `getFileRecord` has to a blob, so
  the route inherits it. A blob referenced by more than one notebook stays
  readable when *any* referencing notebook is the caller's, matching the
  library rule directly above it.

  The router does need one change, though. It resolves its reader as
  `scoped(to: authenticatedClient?.userId)`
  (`KaibaNoteFileHTTPRouter.swift:75`), which is **nil** — the unscoped
  operator view — whenever the request carried no credential, while the
  GraphQL transport resolves the same request to the default user
  (`ServerContracts.swift:259`, `?? NoteStoreSchema.defaultUserId`). An
  enforcement gate keyed on `actingUserId != nil` would therefore never engage
  on the file route of an `--allow-unauthenticated` (or `--as-admin`) host:
  GraphQL would refuse another account's note while `GET /files/<fileId>`
  still served its attachment. **The router resolves the same default-user
  fallback the GraphQL transport does.** That is the smaller and safer of the
  two available fixes: keying the gate on `isUnauthenticatedPrincipal` instead
  would spread the transport's notion of "no credential" into the enforcement
  layer, and the fallback leaves library reach untouched — an unauthenticated
  principal is held to the open libraries by the marker either way, and under
  `--as-admin` the default user is the admin account, so it reaches what it
  reached before.

  **An unreferenced blob is refused to a scoped caller.** For library reach,
  a blob with no referencing notebook is allowed through
  (`NoteService+LibraryEnforcement.swift:88-90`) on the grounds that nothing
  else in the product treats such a blob as private. Ownership does not
  inherit that: an orphaned blob is most often a deleted note's attachment,
  still on disk until `reclaimUnreferencedFiles` sweeps it, and handing those
  bytes to any account holding the id is exactly the leak this section closes.
  A scoped caller therefore fails closed; the unscoped operator view still
  reads it. Nothing legitimate is broken by this, because every `files` row is
  inserted in the same transaction as its `note_files`/`notebook_files`
  reference (`NoteService+Files.swift:194-203`, `:254-263`,
  `NoteService+AgentChat.swift:308-320`), so no flow reads a blob during a
  window in which it is unreferenced.

**Served event and reply routes are scoped.** `GET /note/events` retains the
authenticated principal and uses an opaque, principal-bound cursor: only an
event visible through the scoped `NoteService` advances or wakes that cursor.
It therefore returns neither a store-wide revision nor foreign-write timing.
Each delivery retains its prepared batch under the request cursor and returns
an opaque successor; using that successor acknowledges the batch, while retry
or overlap on the request cursor replays it after rechecking current event
visibility. Revoked events are omitted, and an operational authorization error
returns 500 without consuming the retained batch. Cursor retention and each
cursor's pending event buffer are bounded per principal. A buffer overflow
forces only that cursor to resync, so one caller cannot exhaust feed memory or
evict or wake another caller's poll.
`GET /note/agent-stream` resolves the caller-supplied turn through the same
scoped service before polling. The handler fails closed when no ownership
reader is wired. This extends the served ownership boundary beyond GraphQL and
file bytes.

A refused row is reported **missing, not forbidden**, reusing the wording the
library layer already produces. A distinct "forbidden" answer would confirm
that an id exists in another account, which is the fact being withheld. The
same missing-row behavior now applies to a foreign stream turn, and event
filtering prevents that route from disclosing foreign notebook ids or tags.

Enforcement applies **only when `actingUserId` is set**:

- The unscoped value — the local CLI, and the internal bootstrap paths — keeps
  the operator view of the whole store. A process holding the store file is not
  a boundary that hiding rows can defend.
- An unauthenticated served request resolves to the default user and is
  therefore scoped like any other account. On a host with one account that is
  every notebook, so `--allow-unauthenticated` behaves exactly as before.
- The admin role does not widen it. Admin answers one question — may this
  account reach every library — and ownership is not a library question.

**The long-term memory notebook is internal-only.** It remains a store-wide
singleton carrying `notebook-kind:long-term-memory`, but it is not an ownership
exception. Scoped reads, GraphQL note lookup, and public listing/recall APIs
report it missing; only unscoped processing may create, list, recall, or link
memory until per-user long-term memory replaces the singleton. This prevents a
memory-source link from becoming a cross-account content-discovery path. The
reserved tag assignment remains guarded by
`validateLongTermMemoryNotebookTagAssignment`.

**The tag memo notebook is resolved per owner, not carved out.** It is the
other store-wide-singleton notebook, and unlike long-term memory it sits on the
GraphQL surface this work closes: `ensureTagMemoNotebook` is a mutation and
`tagDetail.memoNotebookId` is a query field. Both resolve it through
`findTagMemoNotebookId` (`NoteService+TagDetail.swift:241-250`), which today
searches the whole store — `WHERE json_extract(meta_json,
'$.kaibaTagMemo.subjectTagId') = ? ORDER BY created_at LIMIT 1` — and then
hydrates the row through `requireNotebook` (`:157`). Left alone, the owner
predicate would make that a **permanent per-tag break**: account B asks for the
memo notebook of a tag whose memo notebook account A happened to create first,
the store-wide lookup returns A's id, `requireNotebook` refuses it, and B can
never create its own because the lookup keeps finding A's row. A single-account
store would not notice.

So `findTagMemoNotebookId` takes the owner predicate itself:
`owner_user_id = ?` when `actingUserId != nil`, unscoped otherwise. That is not
a carve-out — it is the ownership rule applied one level earlier, at the lookup
rather than at the hydration, which is the only place it can be applied to a
find-or-create. The consequences, stated so they are not inferred:

- **`ensureTagMemoNotebook`** finds the caller's own memo notebook for the tag,
  or creates one owned by the caller. Each account gets its own memo notebook
  per tag. If that account's sole tagged source moves to another library, the
  existing memo retains its identity and moves with the source rather than
  creating a second owner/tag memo. Rehoming first requires the account to
  retain reach to the memo's current library; a revoked account receives the
  ordinary missing-row result and cannot use a moved source to pull an
  inaccessible memo into a reachable library.
- **`tagDetail.memoNotebookId`** reports the caller's own memo notebook, or nil
  when they have none. A scoped caller never receives another account's
  notebook id, which is what the "missing, not forbidden" rule above already
  promises.
- **Unscoped** (CLI, operator view) is unchanged: still the earliest matching
  notebook store-wide.

The store already permits this. Only long-term memory has a uniqueness guard
(`validateLongTermMemoryNotebookTagAssignment`, `NoteTagWrites.swift:45`);
nothing constrains the number of notebooks carrying
`NoteStoreSchema.tagMemoNotebookKindTag`, so a second per-owner memo notebook
needs no schema change and no guard removed. This is also why the tag memo
notebook is *not* handled the way long-term memory is: a carve-out would make
one account's hand-written memos readable and writable by every other account,
which is a content leak, whereas long-term memory is carved out precisely
because its singleton guard leaves no alternative.

### Attribution on the API

The API models follow the columns, which are not the same on both tables.
`notebooks` carries `owner_user_id`, `created_by`, and `updated_by`; `notes`
carries only `created_by` and `updated_by`, because a note reaches its owner
through its notebook and holds no owner column of its own (see Ownership,
above). So:

- **`Notebook`** gains `ownerUserId`, `createdBy`, and `updatedBy`.
- **`Note`** gains `createdBy` and `updatedBy` only. It gets **no**
  `ownerUserId`. Adding one would mean either selecting a column that does not
  exist or joining `notebooks` into every note loader to synthesize a value the
  caller can already reach through `notebookId` — a per-row join added to the
  hottest read path in the store, to publish a fact that is one hop away.

All of them are **optional**, on the `libraryId` precedent (`Notebook` only —
`Note` has no such field, so the precedent is about the shape, not the field):
the row always has these values, but a read that does not select the columns
leaves them nil rather than inventing the default user. Optional-with-a-default
also keeps every existing construction of these structs compiling.

The GraphQL contract exposes them as nullable `String` — three fields on
`Notebook`, two on `Note` — and the executor's field projection accepts them.
Existing selections keep working because a GraphQL client asks for the fields
it wants; adding a field to a type breaks nothing that did not ask for it.

**Schema changes bump the version.** Kaiba carries no migrations: any change
to the create schema increments `NoteStoreSchema.currentVersion`, and a store
created at another version is refused and recreated. Backward compatibility
with existing stores is not a requirement.

Attribution is exposed **after** ownership enforcement is in place, never
before. The fields name accounts, and publishing an account id on a read path
that has not yet been closed would widen the very leak this work exists to
close.

### The agent token route

The hand-off above is wired to one route:

```
POST /note/agent-token
Authorization: Bearer <note API credential>
{"ttlSeconds": 900}          # optional
-> 200 {"token": "...", "userId": "...", "expiresAt": "...", "ttlSeconds": 900}
```

- **The account is never named by the caller.** The route mints for the
  authenticated principal the note API already resolved
  (`NoteAPIAuthenticatedClient.userId`) and reads no user field from the
  request body. A route that accepted `--user` would let any credential mint a
  token for any account, which is the whole risk in one parameter.
- **An unauthenticated request is refused**, including on a host started with
  `--allow-unauthenticated`. Serving an open port is a decision about that
  port; a minted token is a bearer credential that keeps working from anywhere
  else, and outlives the operator turning the flag back off. A host with no
  authenticator configured answers 503, the same answer the other `/note`
  routes give.
- **A disabled account is refused**, by `issueAuthToken` re-reading the user
  rather than trusting the credential.
- **TTL is bounded by the server.** An absent `ttlSeconds` takes the server's
  short default; a present one may ask for a shorter life. A non-integral,
  non-positive, or over-long value is refused rather than clamped, so a caller
  is never told it got what it asked for when it did not. Both the default and
  the ceiling are server constants.

The route lives on the existing `/note` namespace next to `/note/register`,
`/note/events`, and `/note/agent-stream`, and is refused with 405 on any other
method, matching those routes.

### Non-Goals

- Sharing a notebook between users, and any per-note ACL. Ownership is one
  user per notebook.
- Roles beyond admin: no per-library operator, no read-only role. `admin`
  answers one question — may this account reach every library.
- Admin access to another account's notebooks. Ownership scoping is unchanged
  by the role.
- Per-user tag namespaces.
- Migrating an existing single-user store. The store is recreated, per the
  project's fresh-schema policy.

## Enforcement Status

Implemented: the user table and default user, notebook ownership and
attribution columns, catalog scoping, per-user API clients, `--jwt` on the CLI,
per-request GraphQL scoping, ownership enforcement below the catalog (by-id,
bulk, and attachment bytes), served event and reply stream scoping,
principal-preserving tag-grounded chat context, API model/GraphQL attribution,
and `POST /note/agent-token`.

Deliberately still open, and recorded rather than quietly closed:

- **`created_by`/`updated_by` under notebook sharing.** The stamping helpers
  (`stampNoteCreated`, `stampNoteUpdated`) already record the *acting* user.
  The remaining owner-derived sites are the raw-SQL internal paths — long-term
  memory and agent chat — which run unscoped, where the acting user and the
  notebook owner are the same account. Sharing is a Non-Goal, so the two values
  cannot diverge today; when sharing lands, those sites must switch to the
  acting user. The item stays open until then.
- **Per-user long-term memory.** See the internal-only boundary above.

Implemented tag-detail library scope: `listTagComments`, both
`taggedEntityCount` calls, and `findTagMemoNotebookId` apply reachable-library
predicates before pagination, aggregation, or memo selection. AppCore and
GraphQL regressions cover unauthenticated and revoked-member refusal for
protected comments and counts.

This surface is security-bearing and is the yardstick for adversarial review:
ownership boundaries, principal-bound token issuance and validation, and stream
authorization.

## Verification

- `swift test`: default user exists on a fresh store, is unique, and survives
  reopening; a scoped service sees only its own notebooks; an unscoped service
  sees all; API clients resolve to their user; writes record `created_by` and
  `updated_by`; tokens round-trip, reject tampering, expiry, foreign stores, and
  disabled accounts.
- `swift test`, ownership: a scoped service is refused another account's
  notebook, note, comment, link, and file by id, and is refused the mutation
  paths for the same ids; search, `listNotes`, graph neighbors, and the tag
  detail aggregates return none of the other account's rows; the unscoped
  service still reads both accounts; a single-account store behaves as before.
- `swift test`, tag memo notebooks: two accounts each call
  `ensureTagMemoNotebook` for the same tag; both succeed, each gets its own
  notebook, and neither `tagDetail.memoNotebookId` reports the other's id. This
  is the case a single-account store cannot catch.
- `swift test`, links: a scoped service is refused when it names another
  account's note as either endpoint of `linkNotes`, so the boundary is proven
  on the write path and not only on the read path. Linking to a *read-only*
  note the caller owns still succeeds, which pins the read-level semantics
  against a later drift to the writable variant.
- `swift test`, attachments: `KaibaNoteFileHTTPRouter` answers 404 for a blob
  whose only referencing notebook belongs to another account, and still serves
  one the caller owns — asserted on an authenticated host **and** on an
  `--allow-unauthenticated` one, which is the configuration where the router's
  acting-user fallback is what makes the check engage. A blob left with no
  referencing notebook is refused to a scoped caller and still read by the
  unscoped operator view.
- `swift test`, token route: an authenticated caller receives a token for its
  own account and no other; an unauthenticated caller, a caller whose
  credential is rejected, and a caller whose account has been disabled are all
  refused; an out-of-range TTL is refused.
- `swift test`, served transport and tag grounding: event polling omits a
  foreign notebook id and tag names; a foreign reply turn is refused before
  stream polling; and a queued tag-memo reply never sends another account's
  tagged note body to the provider.
- Manual: `kaiba user add`, `kaiba auth token issue`, then
  `kaiba --jwt <token> notebook create` and `notebook list` showing one user's
  catalog against the unscoped operator view.
