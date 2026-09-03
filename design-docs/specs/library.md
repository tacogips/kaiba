# Libraries

**Status**: Implemented
**Related**: `design-docs/specs/multi-user.md`, `design-docs/specs/note-api-auth.md`,
`design-docs/specs/command.md`

## Purpose

Group notebooks into named libraries, decide per library whether reaching it
requires authentication and which accounts may reach it, let every command
select one, and let a caller list the libraries a store holds.

A library is the unit an operator hands out: a personal scratch library that
keeps working without a login, and a shared library that only granted accounts
can read, in the same store.

## Current State

State before this work, kept for the reasoning it explains.

- A store holds one flat catalog of notebooks (`notebooks`, `NoteStoreSchema.swift:433`).
  The only grouping is tags, including the `folder` tag class used for notebook
  folder paths (`NoteService.swift:63`, `NoteService+Hydration.swift:138`).
- Authentication is per principal, not per collection. `NoteService.actingUserId`
  is `nil` (unscoped, the CLI default) or a user id resolved from `--jwt`;
  unscoped means the whole store is visible (`CommandAuth.swift`, `runAuthWhoami`).
- `kaiba serve` decides authentication once for the process:
  `--allow-unauthenticated` installs no authenticator, otherwise a QR client
  registration authenticator is installed (`ServeCommand.swift:136`).
- The store carries no migrations. `requireSupportedVersion` in
  `NoteStoreSchema.swift` rejects a store older *or* newer than
  `currentVersion`.
- Credentials are never written to `~/.config/kaiba/config.json`; the config
  names environment variables (`authTokenEnvironmentVariable`,
  `accessKeyIdEnvironmentVariable`) and the value arrives through the process
  environment.

## Design

### The library row

```sql
CREATE TABLE libraries (
  library_id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  auth_required INTEGER NOT NULL DEFAULT 1 CHECK (auth_required IN (0,1)),
  is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0,1)),
  created_at TEXT NOT NULL,
  created_by TEXT REFERENCES users(user_id)
) STRICT
```

- `name` is the handle a command types, unique on a normalized (lowercased,
  trimmed) form, enforced by a unique index rather than by convention.
- At most one row carries `is_default = 1`, enforced by a partial unique index.
- The default library is seeded on first store creation next to the default
  user, with the stable literal id `library-default` so every process agrees on
  it without a lookup by flag.
- The default library is seeded with `auth_required = 0`. Everything that
  exists today keeps working unauthenticated; the restriction is opt-in per
  library.

### Membership is a partition, not a set union

```sql
ALTER TABLE notebooks ADD COLUMN library_id TEXT NOT NULL REFERENCES libraries(library_id)
```

A notebook belongs to exactly one library. A many-to-many membership table
would let one notebook sit in an `auth_required = 1` library and an
`auth_required = 0` library at once, and "is authentication required for this
notebook" would then have two answers. Notes, files, comments, and links reach
their library through their notebook and carry no column of their own, for the
same reason ownership is not repeated on them.

### Who may reach a library

Two questions, answered by two pieces of state:

- **`libraries.auth_required`** — may a caller that presented *no credential*
  see this library at all.
- **`library_members`** — which *accounts* may.

```sql
CREATE TABLE library_members (
  library_id TEXT NOT NULL REFERENCES libraries(library_id),
  user_id TEXT NOT NULL REFERENCES users(user_id),
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
  granted_at TEXT NOT NULL,
  granted_by TEXT REFERENCES users(user_id),
  PRIMARY KEY (library_id, user_id)
) STRICT, WITHOUT ROWID
```

The resulting rule, in order:

1. A selected library (`--library`) excludes every other one; a selection
   narrows reach and never widens it.
2. A caller with no credential — an `--allow-unauthenticated` note-API
   request — reaches only `auth_required = 0`.
3. An authenticated **admin** reaches every library, with no grant needed
   (`design-docs/specs/multi-user.md`).
4. Any other authenticated account reaches `auth_required = 0` plus the
   libraries it holds a `library_members` row for.
5. The unscoped local CLI is the operator view and reaches everything. It
   holds the store file, so hiding rows from it would be theater.

Step 2 is checked **before** steps 3 and 4, and that ordering is load-bearing:
an unauthenticated note-API request already resolves to the default user
(`ServerContracts.swift`, `actingUserId: ... ?? defaultUserId`), and that user
is the seeded admin, so its role — like any grant it holds — would otherwise
become a way in for callers with no credential at all. The two cannot be told
apart by account, so the transport carries the distinction explicitly as
`isUnauthenticatedRequest`, which the executor turns into
`NoteService.isUnauthenticatedPrincipal`.

An operator who *wants* an open port to have the admin's reach says so:
`kaiba serve --allow-unauthenticated --as-admin` drops the marker, so
credential-less requests act as the admin account on every route, the
`/files/<id>` byte route included. Without it, `--allow-unauthenticated` keeps
answering only from `auth_required = 0`.

An open library needs no membership rows — "open" already means everyone. The
creator of a library is recorded as its `owner`, or an authenticated caller
would lock itself out of what it just made.

Because the default library is seeded at `auth_required = 0` and every
notebook lands there unless one is selected, an existing deployment answers
exactly as it did before libraries existed until an operator marks something.

Revoking access hides work; it never deletes it. The notebooks stay in the
library, and an operator who wants them elsewhere moves them.

### Selecting a library

```
kaiba --library <name> <subcommand>
KAIBA_LIBRARY=<name> kaiba <subcommand>
```

Resolution order is the explicit flag, then the environment variable, then the
default library. Writes without a selection land in the default library, so
`kaiba add` keeps its current one-line behavior.

### Command surface

```
kaiba library list    [--json]
kaiba library show    <name>
kaiba library create  <name> [--title <t>] [--auth required|none]
kaiba library update  <name> [--title <t>] [--auth required|none]
kaiba library delete  <name>
kaiba library move    <notebook-id> --to <name>
kaiba library grant   <name> --user <user-id> [--role owner|member]
kaiba library revoke  <name> --user <user-id>
kaiba library members <name>
```

- `library list` reports name, title, `authRequired`, notebook count, and which
  row is the default. It is filtered by the same rule as everything else: a
  caller with no credential does not learn that an authenticated library
  exists. The selection is deliberately ignored here — `list` is the catalog of
  libraries, so `--library` must not narrow it to one.
- `library delete` refuses a non-empty library and refuses the default library.
  It never cascades into notebooks; moving them out first is the operator's
  explicit act.
- `--library` is a global option, so it applies to `add`, `list`, `search`,
  and `notebook ...` in either position. Naming a library the caller cannot see
  fails with the same message as a missing one, so the flag cannot be used to
  probe for hidden libraries.
- `library env` reports a library's kinko scope and the environment variable
  names its storage reads from. Never a value.
- `library grant` is idempotent and promotes an existing member's role rather
  than failing, so an operator can raise someone without revoking first.
  `library members` is readable only by a caller that can reach the library:
  who may get in is as private as the library itself.
- The GraphQL schema gains a `libraries` query and `Notebook.libraryId`,
  resolved through the same per-request scoping the executor already applies.

### Per-library credentials and kinko

A library that requires authentication tends to want its own storage
credentials. The config keeps naming environment variables and never holds a
secret:

```json
{
  "database": { "kind": "sqlite" },
  "libraries": [
    { "name": "shared", "storageProfile": "gateway", "kinkoPath": "logical:kaiba/shared" }
  ],
  "storageProfiles": [ { "name": "gateway", "...": "unchanged" } ]
}
```

`auth_required` lives in the store, not here. The config binds a library to a
credential scope; the store decides policy. Two sources of truth for the same
flag is how they drift.

kinko already scopes secrets by `--path` with a shared fallback, so a library
maps onto that scope rather than teaching kinko about kaiba:

```bash
kinko --path logical:kaiba/shared exec -- kaiba --library shared serve
```

`kaiba library env <name>` prints the environment variable names the library
needs and the kinko scope that supplies them, so the operator never assembles
that invocation by hand. If a literal `kinko --library <name>` flag is wanted
later, it is a thin alias over `--path logical:kaiba/<name>` and needs no
kaiba-side change.

## Schema Consequence

`libraries`, `library_members`, and `notebooks.library_id` are part of the base
schema. The store carries no migrations: an older store is refused with
`unsupportedLegacyVersion` and is recreated rather than upgraded. Backward
compatibility is not a requirement.

`notebooks.library_id` is `NOT NULL ... DEFAULT 'library-default'`. The default
is not decoration: the internal paths that create notebooks — long-term memory
bootstrap, imports — keep their existing column lists and still land in a real
library, so no write path can produce an ungrouped notebook.

Derived notebooks are the exception that needs care. A conversation saved from
a source note inherits that note's library (`inheritedLibraryId`), because
landing it in the default library would carry the transcript of an
authenticated library into an open one.

## Interaction With Ownership

`multi-user.md` records that ownership is enforced in the catalog but **not**
below it: fetching a notebook or note *by id* does not check the owner, and
attached files served by `KaibaNoteFileHTTPRouter` are unchecked.

The library boundary does **not** inherit that gap: it is enforced below the
catalog as well. Holding a note, notebook, or file id does not get a caller
past it.

Enforcement lives in `NoteService+LibraryEnforcement.swift` and works by
shadowing. The unguarded row readers were renamed `loadNote` / `loadNotebook`
/ `loadWritableNote` / `loadWritableNotebook`, and `NoteService` now carries
methods under the old names (`requireNote`, `requireNotebook`, ...) that load
the row and then check reachability. Every call site inside a `NoteService`
extension therefore routes through the check without being edited one by one,
and any new path that fetches a row by id is guarded by default. The few
remaining free-function callers — FTS bookkeeping, graph edge reads — call
`load*` explicitly, because they run on ids their caller already authorized.

Bulk reads cannot use a per-row check without a query per hit, so they take a
`reachableLibraryIds` scope inside the SQL: search (FTS, LIKE fallback,
filter-only, and linked-neighbor eligibility), the cross-notebook note feed,
and memo search. Applying it in the query rather than to the results also
keeps a page from silently shrinking.

Graph traversal is the one path that can *arrive* somewhere unreachable: a
link may cross libraries. Seeds are checked on the way in and results are
filtered on the way out (`filterReachable`).

`GET /files/<id>` serves bytes without going through the GraphQL executor, so
it distinguishes "allowed through without a credential" from "authenticated"
and marks the reader accordingly. A file is reachable when any notebook that
references it is; an unreferenced blob stays readable, because nothing else in
the product treats one as private.

A refusal is reported as `notFound`, identical to a bogus id. A distinct
"forbidden" would confirm that an id exists in a library the caller was told
nothing about.

**Still open, deliberately**: reach *inside* a library. Two members of the
same library can still fetch each other's notebooks by id — the notebook
ownership gap `multi-user.md` records. Authorization is per library and per
account; it is not per notebook.

## Non-Goals

- Per-notebook access control inside a library. Membership decides who gets
  into the library; who owns which notebook inside it is `multi-user.md`.
- Roles that mean anything beyond bookkeeping. `owner` records who created or
  was promoted in a library; it does not yet gate any operation that `member`
  cannot do.
- A notebook in more than one library.
- Moving a library to a separate database or file root. A library is a grouping
  inside one store; `--note-root` remains the physical boundary.
- Replacing folder tags. Folders stay the in-library organization.

## Verification

- `Tests/AppCoreTests/NoteLibraryTests.swift` (14 tests): a fresh store has
  exactly one default library at `auth_required = 0` and keeps exactly one
  across re-preparation; notebooks land in the default library without a
  selection; a selected library takes writes and filters reads; names are
  normalized, unique, and reject punctuation and blanks; `create` defaults to
  requiring authentication; an unauthenticated principal sees only open
  libraries and their notebooks while an authenticated one sees all; `delete`
  refuses a non-empty and the default library and removes an empty one;
  `move` re-parents a notebook and leaves its notes and tags intact, and
  rejects an unknown library or notebook.
- `Tests/AppGraphQLTests/NoteGraphQLLibraryTests.swift` (6 tests): the
  `libraries` query and `Notebook.libraryId` over the note API, an
  unauthenticated request restricted to open libraries, and the regression
  that the local `kaiba graphql` operator path is **not** unauthenticated —
  inferring the marker from `authenticatedClientId` hid the operator's own
  libraries from them.
- Manual (`kaiba --note-root <tmp>`): create/list/show/update/delete/move/env,
  writing into a selected library, `KAIBA_LIBRARY`, refusal of an unknown
  selection, and refusal of a non-empty or default delete.
