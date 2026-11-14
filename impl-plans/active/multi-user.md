# Multi-User Note Store

**Status**: In Progress
**Design Reference**: `design-docs/specs/multi-user.md`
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
- [ ] Ownership enforcement on by-id reads and on attached files.
- [ ] `created_by` / `updated_by` exposed on the API models.
- [ ] Server route handing an agent a token for the calling user.

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
**Parallelizable**: No

`listNotebooks` filters by owner, but by-id reads do not. A caller who learns
another user's notebook or note id can still read it. Add an ownership check to
the note, notebook, comment, link, file, and search paths, and to
`KaibaNoteFileHTTPRouter`.

**Completion Criteria**:

- [ ] A scoped service cannot read or mutate another user's note by id.
- [ ] Search results never cross an ownership boundary.
- [ ] Attachment bytes are refused across users.
- [ ] Internal bootstrap paths (long-term memory, agent chat) keep working.

### TASK-M07: Expose attribution on the API

**Status**: Not started
**Parallelizable**: Yes

Select `owner_user_id`, `created_by`, and `updated_by` into `Notebook` and
`Note`, and add them to the GraphQL contract so the viewer can show authorship.

**Completion Criteria**:

- [ ] Both models carry the fields.
- [ ] The GraphQL schema exposes them.
- [ ] Existing selections keep working.

## Progress Log

- 2026-08-16: TASK-M01 through TASK-M05 implemented and verified. `swift build`
  clean; 404 XCTest and 32 swift-testing tests pass, including 10 new
  multi-user tests and 10 new token tests. Verified end to end through the CLI:
  a fresh store seeds the default user, `auth token issue` mints a token,
  `--jwt` scopes the invocation, and one user's `notebook list` shows only their
  own notebooks while the unscoped view shows all. TASK-M06 and TASK-M07 remain;
  M06 is the security-relevant one.
