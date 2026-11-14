# Multi-User Note Store

**Status**: Draft
**Related**: `design-docs/specs/note-api-auth.md`, `design-docs/specs/kaiba-note.md`

## Purpose

Let one kaiba store serve several people, each seeing their own notebooks,
while an unauthenticated host keeps working exactly as it does today by acting
as a single default user.

## Current State

There is no account of any kind. `api_clients` records opaque credentials with
no owner (`Sources/AppCore/NoteService+APIClients.swift`), and every notebook,
note, file, and tag is global: any authenticated caller sees the whole store.
The schema carries no user table and no ownership column.

The store is fresh-schema-only. `NoteStoreSchema.currentVersion`
(`Sources/AppCore/NoteStoreSchema.swift:11`) is created directly, older stores
are rejected with `unsupportedLegacyVersion`, and there are no migrations. Adding
tables therefore means bumping the version, and existing stores are refused
rather than upgraded — the project's established policy.

## Design

### Users

```sql
CREATE TABLE users (
  user_id TEXT PRIMARY KEY,
  email TEXT,
  display_name TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,
  is_admin INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  disabled_at TEXT
)
```

- `email` is optional, because the default user has no address, and unique on a
  normalized (lowercased, trimmed) form when present.
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

They are derived from the row's notebook owner rather than threaded through as
an actor parameter. Under this design that is the same value — one owner per
notebook, no sharing — and it works from the free functions that write notes
without any plumbing. **When notebook sharing arrives, this must change**: the
columns then have to carry the request's acting user, and deriving them from
the owner would silently credit the wrong person.

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

## Not Yet Enforced

Implemented so far: the user table and default user, notebook ownership,
attribution columns, catalog scoping, per-user API clients, `--jwt` on the CLI,
and per-request scoping in the GraphQL executor.

Still outstanding, and deliberately called out because the gap is a real one:

- **Read and write enforcement below the catalog.** `listNotebooks` filters by
  owner, but fetching a note or notebook *by id* does not yet check ownership,
  so a caller who learns another user's id can still read it. Closing this
  means an ownership check in the note, file, comment, link, and search paths.
- **Attached files** served by `KaibaNoteFileHTTPRouter` are not ownership
  checked.
- **`created_by`/`updated_by` are not exposed** on the API models; they are
  stored and queryable but not selected into `Note` or `Notebook`.
- **Server-side token issuance** for the agent hand-off exists in the service
  (`issueAuthToken`) but is not yet wired to an HTTP route.

## Verification

- `swift test`: default user exists on a fresh store, is unique, and survives
  reopening; a scoped service sees only its own notebooks; an unscoped service
  sees all; API clients resolve to their user; writes record `created_by` and
  `updated_by`; tokens round-trip, reject tampering, expiry, foreign stores, and
  disabled accounts.
- Manual: `kaiba user add`, `kaiba auth token issue`, then
  `kaiba --jwt <token> notebook create` and `notebook list` showing one user's
  catalog against the unscoped operator view.
