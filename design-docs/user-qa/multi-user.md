# Multi-User Note Store — Decisions

Design reference: `design-docs/specs/multi-user.md`

## Answered

### Which credential authorizes the agent token route?

The note API credential the server already resolves, and only that. The route
mints for `NoteAPIAuthenticatedClient.userId` and reads no account name from
the request. An unauthenticated request is refused even on a host started with
`--allow-unauthenticated`: an open port is a decision about that port, while a
minted token keeps working from anywhere else and outlives the flag being
turned back off.

### Does the token route accept a caller-supplied TTL?

Yes, bounded. An absent value takes the server's short default; a present one
may only shorten. A non-integral, non-positive, or over-long value is refused
rather than clamped, so a caller is never told it got the life it asked for
when it did not.

### Where does ownership enforcement live relative to library reach?

In the same layer (`NoteService+LibraryEnforcement.swift`), not a parallel one.
That file already shadows the unguarded row readers under the `require*` names
every service path calls, so one predicate reaches every by-id path at once,
and two guards on one chokepoint cannot drift apart.

### Is search scoped in SQL or by dropping rows afterwards?

In SQL, alongside the library predicate already carried by `NoteSearchScope`.
Dropping rows after the query would hand a caller a shorter page than it asked
for without saying so.

### Does the ownership boundary inherit the unreferenced-blob carve-out?

No. Library reach lets a blob with no referencing notebook through, because
nothing else in the product treats such a blob as private. Ownership fails
closed for a scoped caller instead: an orphaned blob is usually a deleted
note's attachment that survives until the reclaim sweep, and serving those
bytes to any account holding the id is the leak the boundary exists to close.
The unscoped operator view still reads it. No legitimate flow is affected —
every `files` row is written in the same transaction as its reference.

### Does the file route need a change of its own?

Yes, one. It resolves its reader to a nil acting user when the request carried
no credential, while the GraphQL transport resolves the same request to the
default user. Without the same fallback, the ownership gate would never engage
on `GET /files/<fileId>` for an `--allow-unauthenticated` or `--as-admin`
host, so that host would refuse another account's note over GraphQL while
still serving its attachment bytes. The router takes the default-user
fallback; library reach is unaffected either way.

### Which `require*` variant guards a link endpoint?

The read-level `requireNote`. The variant follows what the path does to the
row, not whether the call is nominally a write: a link inserts into
`note_links` and modifies neither note, and both endpoints are validated today
with the read-level `loadNote`. The writable variant would refuse a read-only
endpoint, and those are ordinary — imported document pages are read-only by
default, and agent chat cites exactly such a page. This work adds ownership to
these paths and nothing else.

### Does `Note` get an `ownerUserId` field?

No. `notes` has only `created_by` / `updated_by`; `owner_user_id` lives on
`notebooks` alone, because a note reaches its owner through its notebook. So
`Notebook` gains all three and `Note` gains two. Synthesizing `Note.ownerUserId`
would mean joining `notebooks` into every note loader to publish a fact the
caller already reaches through `notebookId`.

### Does exposing `owner_user_id` / `created_by` / `updated_by` break fixtures?

No. The fields are optional with defaults, appended to the initializers, and no
existing test compares a whole `Note` or `Notebook` value against a
hand-constructed one — the tests assert individual fields. Reads that do not
select the columns leave them nil, matching how `libraryId` already behaves.

## Pending

### Should `created_by` / `updated_by` be threaded as the acting user everywhere now?

**Status**: Carried forward, deliberately not closed.

The stamping helpers already record the acting user. The remaining
owner-derived sites are the raw-SQL internal paths (long-term memory, agent
chat), which run unscoped, so the acting user and the notebook owner are the
same account there. Notebook sharing is an explicit Non-Goal, so the two values
cannot diverge today and there is nothing to fix yet. The item stays open until
sharing lands, at which point those sites must switch — it must not be checked
off on the grounds that sharing has not arrived.

### Should `/note/agent-stream` and `/note/events` be scoped now?

**Status**: Pending, deferred to `impl-plans/active/note-api-auth.md`.

Neither route enters `NoteService`, so the ownership predicate does not reach
them: the agent stream serves any turn note by id, and the change feed hands
every poller each mutation's `notebookId` and `tagNames`. Both are open item 6
of `design-docs/specs/note-api-auth.md:115-124`, and the fix is the same one
that closes the library boundary there — carry the authenticated `userId` the
routes currently discard, filter the feed through `reachableLibraryIds`, and
resolve the turn note through `requireNote`. That plan is out of scope for this
work, so this work records the gap rather than closing it, and the boundary
claim here is scoped to the GraphQL surface and the file-byte route.

### Should the tag memo notebook become per-user?

**Status**: Answered — yes, per owner.

Same question shape as long-term memory, opposite answer, because the
constraint differs. Nothing in the store limits how many notebooks carry
`notebook-kind:tag-memo` (only long-term memory has a uniqueness guard), so
each account can hold its own memo notebook per tag. `findTagMemoNotebookId`
therefore takes the owner predicate when the caller is scoped:
`ensureTagMemoNotebook` finds or creates the caller's own, and
`tagDetail.memoNotebookId` reports the caller's own or nil.

The alternative — carving it out the way long-term memory is carved out — was
rejected: tag memos are hand-written user content, so sharing them across every
account is a content leak. Long-term memory is carved out only because its
singleton guard leaves no other option. Doing nothing was also rejected: the
ownership predicate would otherwise turn `ensureTagMemoNotebook` into a
permanent per-tag `notFound` for every account but the first.

### Should long-term memory become per-user?

**Status**: Pending.

The long-term memory notebook is a store-wide singleton keyed by
`notebook-kind:long-term-memory`, so a second account cannot own a second copy.
Ownership enforcement therefore carves it out rather than locking every account
but its creator out of the store's memory. Today it is reached only unscoped
(bootstrap, no GraphQL field, no CLI command), so the carve-out changes no
behavior. Making memory per-user means dropping the singleton guard in favor of
one notebook per owner, which is a larger change than closing this boundary.

### Should the tag detail aggregates carry a library predicate?

**Status**: Pending, tracked against `design-docs/specs/library.md`.

Those queries carry no library scope today — a pre-existing gap, not one this
work introduces. The owner predicate added here keeps them from crossing an
ownership boundary but does not close the library one.
