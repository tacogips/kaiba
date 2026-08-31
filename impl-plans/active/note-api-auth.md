# Note API Authentication

**Status**: RECONCILED — browser-driven-login backlog; not an implementation
target of workflow `codex-design-and-implement-review-loop-session-46`
**Design Reference**: `design-docs/specs/note-api-auth.md`
**Decisions**: `design-docs/user-qa/note-api-auth.md`
**Related implementation plan**: `impl-plans/completed/multi-user.md`

**Latest related implementation evidence**: Step 6's current revision resolves
authoritative prior finding
`codex-design-and-implement-review-loop-session-50-step6-implement-self-review-attempt-1-finding-1`.
It retains a non-reusable process-group ownership witness after gateway
`waitpid` while enumerating descendants separately. Completion requires a
descendant-free exit to skip grace/SIGKILL and final escalation to wait for all
descendants to disappear before reaping the witness or delivering cancellation.
Detailed verification is recorded in the completed multi-user plan before
renewed review; no browser-login backlog item was implemented.

- 2026-08-31: comm-000621 verification passed: focused AI dispatch/stream/recovery
  tests (71 XCTest), eight repeated interleaving runs, SwiftLint with two
  pre-existing warnings, Swift build, and `mise run check` (651 XCTest and 37
  Swift Testing tests plus web and Tauri checks). No browser-login backlog item
  was implemented.

- 2026-08-31: comm-000623 adds bounded stream-payload and terminal-final-attempt
  recovery evidence. The stream API emits `resync=true` after payload eviction,
  while the current lease can still finish a pending poll. Recovery cancels a
  deleted durable target and cancels a failed provider-free final reconciliation
  without re-entering provider retry. No browser-login backlog item was
  implemented. Focused and repeated regressions passed; `mise run web:check`
  and `mise run check` passed (654 XCTest, 37 Swift Testing, 156 Bun, and 34
  Vitest tests; SwiftLint, web build, and Tauri checks).

- 2026-08-31: comm-000625 adds chunk-count and constant-time payload accounting
  to the related reply-stream hardening and makes `MemoTab` discard incomplete
  partial output after `resync=true`. No browser-login backlog item was
  implemented; focused stream tests passed across eight runs, `mise run
  web:check` passed (156 Bun, 35 Vitest), and `mise run check` passed (655
  XCTest, 37 Swift Testing, SwiftLint, web, and Tauri).

## Execution Boundary

The 2026-08-30 reconciliation removes the obsolete `auth_users`, `ks_` session,
and terminal-only HTTP-login shape from this plan. The current workflow's code
step implements multi-user TASK-M06 through TASK-M08 and TASK-M10, shipped
TASK-408, and the accepted agent-token subset of TASK-409; TASK-M09 is already
complete. It must not begin the remaining tasks below, add
`auth_login_requests` or `auth_sessions`, change
`NoteStoreSchema.currentVersion`, or duplicate `POST /note/agent-token`.

`design-docs/specs/note-api-auth.md` is authoritative for later browser-login
work. Any future implementation starts from the dependency order below and
must first choose a schema rollout for `auth_login_requests`. The current
multi-user work requires no schema-version bump and keeps
`NoteStoreSchema.currentVersion` at 17.

## Shipped Baseline

- [x] The SPA has explicit authenticated/unauthenticated state, replaces the
      reader shell with `LoginView` on 401, clears a rejected credential, and
      persists the bearer in `localStorage`.
- [x] `--allow-unauthenticated` is restricted to loopback binds.
- [x] Accounts reuse `users`; there is no `auth_users` table.
- [x] `auth_login_codes`, passwordless email-code issuance and verification,
      fail-closed account lookup, attempt limits, `LogMailSender`, and
      `ResendGatewayCLIMailSender` exist.
- [x] Process credentials are HS256 JWTs whose verification re-reads the user;
      there are no `ks_` tokens or `auth_sessions` rows.
- [x] `kaiba user ...`, `kaiba auth token issue`, `kaiba auth whoami`,
      `kaiba --jwt`, and `kaiba --jwt-env` provide local account management and
      process credentials.

## Remaining Deliverables

- [ ] Effective auth mode and non-secret discovery response.
- [ ] `server.auth` and `server.endpoint` configuration with secret names, not
      secret values.
- [ ] Browser-driven pending-login handoff with a public request id, a separate
      hashed poll secret, a displayed user code, and single-use approval.
- [ ] Browser approval by email link or six-digit code, with GET rendering and
      POST approval so mail scanners cannot consume a login.
- [ ] Bare `kaiba auth login` as a client of a running server; existing
      `request|verify` remain the direct-store fallback.
- [ ] SPA login and approval views selected by `/note/auth-info`.
- [x] Ownership scoping for `/note/events` and `/note/agent-stream`.
- [ ] `Content-Type`, `Host`, and cross-site request guards for mutation routes.
- [ ] Optional IdP federation in `builtin`, then standalone `oidc` mode.

## Dependency Order

1. TASK-202 -> TASK-203 -> TASK-301 -> TASK-302.
2. TASK-402 -> TASK-403 -> TASK-404 and TASK-405.
3. TASK-408 is shipped; TASK-409 may proceed independently under the
   accepted-host and origin policy fixed by P10.
4. TASK-410 is blocked on P6 and is not required for the JWT/polling flow.
5. TASK-501 -> TASK-601 only after the built-in browser flow is complete.

TASK-407 is not in this dependency graph: multi-user TASK-M08 owns the route,
implementation, and tests.

## Tasks

### TASK-101 through TASK-104: SPA unauthenticated state

**Status**: Done.

- [x] A 401 sets unauthenticated state without mounting the reader shell.
- [x] Non-401 transport and GraphQL failures remain errors.
- [x] A 401 clears the stored bearer.
- [x] A valid pasted key can refresh the catalog without a page reload.
- [x] The credential survives tabs and browser restarts.

### TASK-201: Loopback guard for unauthenticated serving

**Status**: Done.

- [x] A non-loopback `--allow-unauthenticated` bind fails before listening.
- [x] `127.0.0.1`, `::1`, and `localhost` remain supported.

### TASK-202: Effective auth mode

Replace transport-level boolean mode selection with an explicit
`none | apiKey | builtin | oidc` value. `--allow-unauthenticated` forces
`none`; `--as-admin` remains valid only with that flag. Preserve the
unauthenticated transport marker because it independently limits library reach.

- [ ] Startup reports the effective mode without secrets.
- [ ] Current `none` and `apiKey` behavior is unchanged.
- [ ] The unauthenticated-host and `--as-admin` tests remain explicit.

### TASK-203: `GET /note/auth-info`

**Depends on**: TASK-202.

Add an unauthenticated discovery route returning only effective mode and the
non-secret facts needed by the SPA. `none` returns only `{"mode":"none"}`.
Issuer and client id may be public; environment names, keys, login codes, poll
secrets, and credentials must never be returned.

### TASK-301: Authentication configuration

**Depends on**: TASK-202.

Add `server.endpoint`, `server.allowedHosts`, `server.allowedOrigins`, and
`server.auth` configuration. CLI flags win over the file. Host authorities and
origins are exact values with no wildcard or suffix matching; `server.endpoint`
does not grant either. Configuration names secret-bearing environment variables
but never contains a credential value. Unknown modes fail startup. External
mail delivery continues through the gateway process, with no API key passed in
arguments, responses, or logs.

### TASK-302: Mode-driven login shell

**Depends on**: TASK-203, TASK-101 through TASK-104.

The SPA fetches `/note/auth-info` and selects the `apiKey`, `builtin`, `oidc`,
or `none` surface. `none` never renders a login prompt. A discovery failure may
offer the existing API-key path but must not expose the reader shell as if the
caller were authenticated.

### TASK-401: Existing identity and JWT baseline

**Status**: Done; replaces the obsolete account/session-storage task.

- [x] Accounts are existing `users` rows with normalized email, disablement,
      and ownership; no parallel account table exists.
- [x] `auth_login_codes` stores hashes and enforces single use, expiry, attempt
      caps, and enabled-account lookup.
- [x] JWT verification checks signature, issuer, expiry, and current account
      state; reserved `auth.*` settings are inaccessible through GraphQL.
- [x] No `auth_sessions` table or opaque `ks_` credential is claimed shipped.

### TASK-402: Pending-login storage and lifecycle

**Depends on**: A future schema-rollout decision outside the current work.

Add `auth_login_requests` exactly as specified: public `request_id` and
`user_code`; hashed `poll_secret` and approval token; nullable approved user;
expiry, approval, consumption, poll count, and last-poll timestamps. Raw
secrets are returned only once to their intended channel, never persisted
server-side, and never logged. A CLI holds the poll secret in memory; a
standalone SPA holds it only in same-origin `sessionStorage` until a terminal
state.

- [ ] Pending, approved, expired, and consumed states are transactional.
- [ ] Approval and the first successful poll are single use under races.
- [ ] Wrong secret, unknown id, expired id, and consumed id are externally
      indistinguishable.
- [ ] Polling faster than the advertised interval returns `slow_down`.

### TASK-403: Browser-driven login routes

**Depends on**: TASK-301, TASK-402.

Implement the authoritative route set, not `/note/login/verify`:

- `POST /note/login/start`
- `POST /note/login/poll`
- `POST /note/login/email`
- `GET /note/login/approve` to render confirmation only
- `POST /note/login/approve` to consume the approval token
- `POST /note/login/code`

Every body route requires JSON except the confirmation-page GET. Start and
email requests answer identically for known and unknown addresses and enforce
per-source and per-account limits before triggering mail. Approval binds the
request, enabled account, displayed user code, and single-use token. Poll hands
the JWT only to the poll-secret holder.

Both CLI and standalone SPA are polling clients. A standalone SPA starts its
own request, stores only `{requestId, pollSecret}` in `sessionStorage`, and
deletes it on success, expiry, cancellation, or authentication failure. Only
the first successful poll returns the JWT; approval and code routes never do.

The Resend adapter remains an external-command boundary: use a fixed executable
and fixed subcommand structure, pass untrusted values as arguments/stdin rather
than shell source, inherit only the intended working directory/environment,
bound execution time and output, and redact command errors before HTTP
responses or logs.

### TASK-404: Browser-driven `kaiba auth login`

**Depends on**: TASK-403.

The bare command starts a pending login against `--endpoint`, prints the
verification URL and user code, opens a browser unless `--no-browser`, and
polls until success, expiry, or cancellation. It never opens SQLite directly.
`auth login request|verify` remain named, direct-store commands for scripts and
hosts with no server. Token output is opt-in and must not appear in normal logs.

### TASK-405: Browser login and approval UI

**Depends on**: TASK-302, TASK-403.

Implement the email/code flow and pending-request confirmation view. With no
incoming `request`, the SPA calls start itself, stores the pending pair in
same-origin `sessionStorage`, polls, deletes the pair at a terminal state, and
stores the returned JWT under `kaiba-note-bearer`. With an incoming CLI
request, the page approves only and never sees the JWT. The UI shows the user
code and requesting client before approval; a bare link GET cannot approve.

### TASK-406: Resend mail sender

**Status**: Delivery seam done; configuration remains in TASK-301.

- [x] `ResendGatewayCLIMailSender` delegates delivery without exposing the API
      key to kaiba.
- [x] Tests use stubs/failing executables, not a live account.
- [ ] Server configuration selects the sender and from-address without storing
      secret values.

### TASK-407: `POST /note/agent-token`

**Status**: Delegated; do not implement here.

Multi-user TASK-M08 is the sole owner because the route's essential contract is
account attribution. It mints only for `NoteAPIAuthenticatedClient.userId`,
accepts no caller-supplied account, bounds TTL, re-reads account state, refuses
all unauthenticated hosts (including `--allow-unauthenticated`), and keeps the
token out of logs. This plan consumes that route after TASK-M08 passes.

### TASK-408: Scope event and agent streams

**Status**: Done; rechecked after comm-000630 incremental lease-fenced delivery remediation

The route handler retains the authenticated user, scopes its store reader to
that principal, omits foreign notebook events before serializing ids or tags,
and authorizes a requested reply turn with `getNote` before attaching to the
stream. Routes fail closed when the ownership reader is not wired. Deleted
notebooks retain internal owner and library snapshots for a deletion refresh
only when the owner still reaches that library; neither snapshot is serialized.
Only `notFound` omits an event — an operational authorization read returns 500
without advancing the client cursor. Event cursors are opaque and
principal-bound; foreign activity neither advances nor wakes a caller's poll.
Prepared event batches remain replayable under their request cursor until the
returned successor cursor is used as an acknowledgment, so transport loss and
overlapping same-cursor polls cannot silently discard an owner-visible refresh.
Each replay rechecks current owner/library reach, omits newly inaccessible
events, and preserves the batch when an operational authorization read returns
the retryable HTTP 500.
An authenticated cursor principal includes both account and client id; cursor
capacity is bounded per such principal and reset requests receive 429 rather
than evicting or waking another client's poll. Unauthenticated allocation is
likewise bounded without eviction. Each cursor's pending-event buffer is
bounded; overflow discards its queued events and returns only that principal a
resync response. A pending operational authorization failure takes precedence
over that resync, so the first poll returns 500 and a same-cursor retry then
receives the principal-local resync.
Regression tests cover foreign event metadata, unauthenticated auth-required
and revoked-library deletion visibility, authorization-read failures,
dropped-response and pre-publication overlapping same-cursor replay, a foreign-only poll,
cross-principal cursor pressure, a foreign stream turn, and a woken
nonterminal stream snapshot that finishes during suspended second
authentication without losing its terminal tail under grace expiry and
retention pressure.

### TASK-409: Cross-site and host hardening

`POST /note/agent-token` now requires `Content-Type: application/json` before
decoding and returns `Cache-Control: no-store` with a successful credential
response. The remaining host and origin hardening stays pending.

Require `Content-Type: application/json` for every state-changing JSON route;
answer 415 before decoding otherwise. Normalize `Host` as specified in P10 and
answer 400 before authentication when it is missing, malformed, or not the bind
authority/loopback alias/exact `allowedHosts` entry. For state-changing
requests, reject `Origin: null` or an origin outside the normalized request
origin and exact `allowedOrigins` list with 403. An absent Origin remains valid
for non-browser JSON clients, including loopback `mode: none`, after Host and
content-type validation. Never trust forwarded-host headers, wildcards, or
`server.endpoint` as authorization. Compute the local origin as `http://` plus
validated Host; an HTTPS proxy must use an exact `allowedOrigins` entry rather
than forwarded proto/host headers. Keep stable bodies and do not echo provider,
credential, code, token, or internal command details.

- [ ] Missing, malformed, unlisted, suffix-lookalike, and wrong-port Host
      values answer 400 before authentication and route execution.
- [ ] The bind authority, loopback aliases on the listener port, and exact
      `allowedHosts` entries are accepted; forwarded-host headers change
      nothing.
- [ ] `Origin: null` and unmatched origins answer 403; same-origin and exact
      `allowedOrigins` values are accepted and use `Vary: Origin` without `*`.
- [ ] Missing Origin still permits authenticated CLI JSON and loopback
      `mode: none` JSON requests; missing/wrong Content-Type answers 415.
- [x] The shipped `/note/agent-token` route rejects missing or non-JSON
      content types with 415 and marks successful credential responses
      `Cache-Control: no-store`.

### TASK-410: Per-device browser sessions

**Status**: Deferred; blocked on P6 in
`design-docs/user-qa/note-api-auth.md`.

Do not add `auth_sessions` or claim sliding expiry until the user decides fixed
versus idle expiry and refresh behavior. JWT-based CLI/agent credentials and
the pending-login handoff do not depend on this task.

### TASK-501: External IdP federation inside `builtin`

**Depends on**: TASK-405.

Use Authorization Code + PKCE as a public SPA client. Verify signature, issuer,
audience, nonce, and expiry, map only a verified email to an existing enabled
`users` row, and issue kaiba's own credential. Cache JWKS with rotation tests;
do not use a live tenant in tests.

### TASK-601: Hosted `oidc` mode

**Depends on**: TASK-501.

Validate issuer access tokens on every request without kaiba session state.
Failures answer 401 without provider detail. `apiKey` remains available for
non-interactive access.

## Verification for Future Authentication Work

Run the narrowest affected suites first, then all repository gates. Whenever
`web/` changes, both web and Tauri checks are mandatory.

```bash
git diff --check
mise run build
PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter KaibaJWTTests
PKG_CONFIG_PATH="$PWD/.build/anydoc-native/host/pkgconfig" mise exec -- swift test --filter AppServerTests
mise run web:check
mise run tauri:check
mise run lint
mise run test
mise run check
```

No test may be skipped, weakened, or converted from a negative authorization
assertion to a success-path-only assertion.

## Progress Log

- 2026-08-16: Phase 1 shipped: explicit SPA auth state, login view, credential
  clearing, and localStorage persistence.
- 2026-08-17: Existing `users`, JWT credentials, passwordless login-code
  service/CLI, and the Resend gateway adapter shipped and were verified.
- 2026-08-30: Reconciled against the browser-driven-login specification. The
  obsolete `auth_users`, `ks_`, `auth_sessions`, and `/note/login/verify`
  implementation shape was removed. Agent-token ownership was assigned solely
  to multi-user TASK-M08. Event-stream ownership, raw HTTP hardening, pending
  login security, external-command boundaries, schema rollout, and the P6
  browser-session decision are now explicit.
- 2026-08-30: Multi-user TASK-M08 retained sole ownership of agent-token
  issuance and added atomic first-use JWT signing-secret initialization with a
  concurrent real-service regression test. TASK-408 and the remaining browser
  login work remain deferred.
- 2026-08-30: TASK-408 shipped with the completed multi-user plan. Event
  polling filters foreign notebook metadata and tag names through the request
  principal's scoped service, and agent-stream authorizes a turn before
  polling. Regression tests cover both foreign-owner refusals.
- 2026-08-30: TASK-408 follow-up preserves owner-visible notebook-deleted
  events after the notebook row is removed, without serializing its internal
  owner or library snapshots. Visibility requires both the captured owner and
  the caller's current library reach; operational authorization failures return
  500 without advancing the client revision. Regressions cover an
  unauthenticated auth-required library, revoked membership, and an injected
  authorization-read failure.
- 2026-08-30: TASK-408 adversarial follow-up replaced the externally visible
  global revision with opaque, principal-bound cursors. A foreign-only event
  neither advances nor wakes a caller poll; a cursor reset requests a scoped
  client refresh. Web polling now preserves the opaque cursor and treats a
  reset as a reconnect refresh.
- 2026-08-30: TASK-408 cursor retention is now bounded per principal rather
  than globally; reset-cursor pressure cannot evict or wake another
  principal's long poll. `NoteEventRouteOwnershipTests` covers the isolation.
- 2026-08-30: TASK-408 also bounds pending events per opaque cursor. Overflow
  drops that cursor's queued events and forces only its principal-local resync;
  cross-principal overflow regression coverage confirms foreign polls remain
  asleep.
- 2026-08-30: Replaced scheduler-yield readiness loops in
  `NoteEventRouteOwnershipTests` with one-second `ContinuousClock`-bounded
  waits for active polling and asynchronous publication. Eight repeated
  event-route runs and the complete Swift suite passed after the correction.
- 2026-08-30: TASK-408 now retains pending owner-visible events across an
  authorization-failed poll. The route returns 500 without a cursor, and the
  next request with the same opaque cursor reauthorizes and delivers the event
  or returns its principal-local resync. `NoteEventRouteOwnershipTests` (11
  XCTest tests), the complete Swift suite (570 XCTest and 34 Swift Testing
  tests), lint, and build passed after the correction.
- 2026-08-30: Final adversarial follow-up binds authenticated event cursors to
  both account and client id, rejects capacity pressure with 429 without
  evicting active polls, and bounds unauthenticated allocation without
  eviction. The tag-grounding regression now selects exactly one `.chat`
  invocation. `/note/agent-token` requires JSON and returns `Cache-Control:
  no-store` on success. Verification passed: `git diff --check`, focused
  authorization suites (115 XCTest tests), `mise exec -- swift test` (573
  XCTest and 34 Swift Testing tests), `mise run lint` (two pre-existing
  non-serious warnings), `mise run build`, `mise run web:check` (156 Bun and
  34 Vitest tests), and `mise run tauri:check`.
- 2026-08-30: TASK-409 Content-Type validation now treats an explicitly empty
  header as non-JSON and returns 415 without indexing an empty media-type
  component. `AgentTokenRouteTests` covers the regression. Verification
  passed: `git diff --check`, focused authorization suites (116 XCTest tests),
  `mise exec -- swift test` (574 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  web:check` (156 Bun and 34 Vitest tests), and `mise run tauri:check`.
- 2026-08-30: Derived agent-chat notebooks now inherit their authorized note
  or notebook subject library; tag-memo notebooks inherit one reachable tagged
  source library and reject mixed-library tags. Tag-grounded replies scope
  their context to the memo library. Saved conversations include every
  transcript source when deriving their library and reject mixed sources.
  GraphQL coverage proves the default unauthenticated principal cannot list or
  read protected-source conversations, turns, or tag memos. Verification
  passed: `git diff --check`, focused ownership suites (107 XCTest tests),
  `mise exec -- swift test` (576 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), and `mise run build`.
- 2026-08-30: Derived-content follow-up closes three remaining library-boundary
  cases. New conversation turns require all existing explicit/link sources to
  share the destination library; new agent-chat turns reject a subject moved to
  another library before a chat provider call; and tag-memo derivation unions
  note-level and notebook-level tag sources, inheriting protected notebook-only
  sources and rejecting mixed libraries. The default-user GraphQL regression
  covers existing protected conversations, moved subjects, and notebook tags.
  Passed `git diff --check`, focused security suites (121 XCTest tests),
  `mise exec -- swift test` (579 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  web:check` (156 Bun and 34 Vitest tests), and `mise run tauri:check`.
- 2026-08-30: Multi-user comm-000471 follow-up snapshots agent-chat subject
  context and conversation/library equality in one transaction before provider
  invocation, then revalidates the same subject while persisting the reply.
  A deterministic paused-provider regression moves the conversation into the
  open library and proves the protected reply cannot be stored there. The chat
  context moved to `NoteService+AgentChatContext.swift` to preserve the
  repository's Swift file-size boundary. Verification passed: `git diff
  --check`, focused security suites (122 XCTest tests), `mise exec -- swift
  test` (580 XCTest and 34 Swift Testing tests), `mise run lint` (two
  pre-existing non-serious warnings), `mise run build`, `mise run web:check`
  (156 Bun and 34 Vitest tests), and `mise run tauri:check`.
- 2026-08-30: Multi-user comm-000473 follow-up binds each agent-reply stream
  chunk to the conversation library captured with the provider context. The
  stream route reauthorizes the turn and all captured libraries after its
  asynchronous poll, so a move to the open library cannot expose protected
  chunks. A deterministic streaming provider regression proves the
  unauthenticated route returns 404 after that move. Verification passed:
  `git diff --check`, focused stream suites (23 XCTest tests), eight repeated
  streaming-boundary runs, `mise exec -- swift test` (581 XCTest and 34 Swift
  Testing tests), `mise run lint` (two pre-existing non-serious warnings),
  `mise run build`, `mise run web:check` (156 Bun and 34 Vitest tests), and
  `mise run tauri:check`.

- 2026-08-30: Multi-user comm-000475 follow-up delays terminal stream
  acknowledgment until `/note/agent-stream` completes post-poll authorization.
  Rejected post-move requests cannot satisfy terminal retention delivery or
  evict protected chunks; a pressured-retention regression confirms a later
  authorized caller receives the terminal stream. Verification passed: `git
  diff --check`, focused stream suites (24 XCTest tests), eight repeated
  regression runs, `mise exec -- swift test` (582 XCTest and 34 Swift Testing
  tests), `mise run lint` (two pre-existing non-serious warnings), `mise run
  build`, `mise run web:check` (156 Bun and 34 Vitest tests), and `mise run
  tauri:check`.

- 2026-08-30: Multi-user comm-000479 follow-up revalidates the captured
  subject/library before a failed turn is persisted. A changed boundary leaves
  provider-derived failure text out of both storage and terminal metadata;
  terminal streams always retain the captured library, including no-chunk
  failures. The deterministic protected-to-open failure regression proves an
  unauthenticated stream poll cannot return the sensitive sentinel, and the
  forged-subject regression asserts `NoteServiceError.invalidInput`.
  Verification passed: `git diff --check`, focused stream and chat suites (54
  XCTest tests), eight repeated no-chunk failure runs, `mise exec -- swift
  test` (583 XCTest and 34 Swift Testing tests), `mise run lint` (two
  pre-existing non-serious warnings), and `mise run build`.

- 2026-08-30: Multi-user comm-000481 follow-up binds failed-turn persistence
  to the immutable captured library as well as the captured subject. The
  deterministic no-chunk failure regression moves both subject and conversation
  from protected to open before its sensitive sentinel, proving persistence and
  unauthenticated stream delivery both fail closed. Verification passed: `git
  diff --check`, focused stream and chat suites (39 XCTest tests), eight
  repeated no-chunk failure runs, `mise exec -- swift test` (583 XCTest and 34
  Swift Testing tests), `mise run lint` (two pre-existing non-serious warnings),
  and `mise run build`.

- 2026-08-30: Multi-user comm-000483 follow-up binds successful turn
  persistence to the immutable captured library as well as the captured
  subject. A deterministic paused-provider regression moves both protected
  subject and conversation open before success, proving no provider-derived
  reply is stored in the now-open conversation. Verification passed: `git diff
  --check`, focused stream and chat suites (54 XCTest tests), eight repeated
  successful-boundary runs, `mise exec -- swift test` (583 XCTest and 34 Swift
  Testing tests), `mise run lint` (two pre-existing non-serious warnings), and
  `mise run build`.

- 2026-08-30: Multi-user comm-000485 follow-up makes edit-mode body mutation
  validate the immutable captured subject and library in the same transaction
  as the guarded note update. The documented committed-edit behavior remains
  unchanged after a valid mutation. A paused edit-provider regression moves
  both protected subject and conversation open before provider completion and
  proves neither the replacement nor turn completion persists. Verification
  passed: `git diff --check`, focused stream and chat suites (55 XCTest tests),
  eight repeated edit-boundary runs, `mise exec -- swift test` (584 XCTest and
  34 Swift Testing tests), `mise run lint` (two pre-existing non-serious
  warnings), and `mise run build`.

- 2026-08-30: Multi-user comm-000490 follow-up adds an edit-mode optimistic
  concurrency check. The immutable provider-context snapshot retains the exact
  note body and the replacement transaction rejects a changed body with
  `NoteServiceError.conflict`. A paused-provider regression confirms a
  concurrent human edit survives the stale AI replacement. Verification
  passed: focused `AgentChatLibraryBoundaryTests`, eight repeated stale-edit
  regressions, `mise exec -- swift test`, `mise run lint`, `mise run build`,
  and `git diff --check`.


- 2026-08-30: Multi-user comm-000495 follow-up makes authenticated and
  authorization-scoped attachment, event, and agent-stream success responses
  non-storable with `Cache-Control: private, no-store`, preventing browser
  cache reuse after revocation or changed library access. Agent-conversation
  creation now validates and inserts the subject-derived notebook in one
  immediate transaction and rejects a deleted or moved pre-insert subject.
  Focused file, event, stream, and agent-chat boundary suites passed, followed
  by `mise exec -- swift test`, `mise run lint`, `mise run build`, and `git
  diff --check`.

- 2026-08-30: Multi-user comm-000500 follow-up rejects an existing API
  credential immediately after its owning account is disabled. Long-poll event
  and reply-stream routes now repeat authentication after suspension and only
  deliver if the same client and user remain valid. Disabled-principal
  auto-action recovery now records an explicit cancelled outbox outcome,
  terminalizes chat and translation state, and finishes matching reply streams
  rather than treating cancelled work as dispatched. Added disabled-key,
  mid-poll-revocation, and cancellation retry/re-enable regressions. Final
  verification: focused security suites, full Swift suite, lint, build,
  web/Tauri checks, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000502 preserves a durable cancellation
  intent in cancelled chat and translation domain state, so recovery after an
  outbox-write boundary cannot reinterpret a safety stop as provider success.
  Event polls now restore an undelivered batch when post-poll authentication
  rejects it. Regressions cover chat and translation cancellation followed by
  account re-enable, plus transient-authentication and disabled/re-enabled
  same-cursor event retries. Verification: focused security suites (25 XCTest
  tests), eight repeated retry-suite runs, `mise run check` (594 XCTest and 34
  Swift Testing tests), `mise run build`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000506 persists disabled-principal tag
  extraction cancellation directly in the leased, version-17-compatible
  `auto_action_dispatch_cancellations` outbox record before acknowledgement.
  Recovery after account re-enable therefore cannot invoke the provider or
  mutate tags after a lost acknowledgement. Agent-chat context now propagates
  operational tag/notebook read errors while treating intentional not-found as
  absent context. Added the tag-extraction outbox-boundary regression.
  Verification passed: focused cancellation, agent-chat boundary, and event
  retry suites (32 XCTest tests); `mise run check` (595 XCTest and 34 Swift
  Testing tests), `mise run build`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000510 keeps derived translation output in its
  protected source library and preserves one per-owner/tag memo notebook when
  a sole tagged source moves libraries. Added unauthenticated translated-note
  refusal and source-library-move ensure/tagDetail regressions. Verification
  passed: focused `AITranslationTests|NoteTagDetailTests` (23 XCTest tests),
  `mise exec -- swift test` (597 XCTest and 34 Swift Testing tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  check`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000512 closes translation source-library
  creation/execution races and the revoked tag-memo rehome path. Translation
  creation and source validation are atomic, execution revalidates the source
  and destination in every output write transaction, and existing owner/tag
  memos require account-level reach before rehoming. Focused
  `AITranslationTests|NoteTagDetailTests` passed (26 XCTest tests); full Swift
  verification passed (600 XCTest and 34 Swift Testing tests).

- 2026-08-30: Follow-up to comm-000514 keeps provider-derived translation
  failure text inside the immutable source/destination library boundary. A
  translation notebook moved protected-to-open during provider invocation now
  remains pending instead of persisting the failure; a deterministic
  unauthenticated-read regression proves the sentinel is absent. TASK-M06 was
  rechecked after focused translation tests (27 XCTest tests), the complete
  Swift suite (601 XCTest and 34 Swift Testing tests), lint, build, `mise run
  check`, and `git diff --check` passed.

- 2026-08-30: Follow-up to comm-000518 makes GraphQL agent-chat replay
  authorize the conversation and return an existing idempotent turn before
  resolving its mutable subject. A GraphQL regression deletes the subject after
  the first committed turn, then proves the same conversation/key returns the
  same turn without inserting a duplicate. The execution boundary now records
  the shipped TASK-408 and accepted TASK-409 agent-token subset. Verification
  passed: focused `AgentChatTests|AgentChatGraphQLTests` (51 XCTest tests),
  `mise run check` (601 XCTest and 34 Swift Testing tests, lint, web, and
  Tauri checks), `mise run build`, and `git diff --check`.

- 2026-08-30: Follow-up to comm-000522 preserves a pending TASK-408
  operational authorization failure through per-cursor buffer overflow and
  returns its 500 before the queued principal-local resync. A same-cursor retry
  then receives `resync: true`; deterministic route coverage combines an
  injected one-time authorization failure with maximum pending-buffer pressure.
  Verification passed: focused event-feed suites (19 XCTest tests), `mise run
  lint` (two pre-existing non-serious warnings), `mise run build`, `mise run
  check` (602 XCTest and 34 Swift Testing tests, lint, web, and Tauri checks),
  and `git diff --check`.

- 2026-08-30: comm-000526 makes TASK-408 authorization reads fail closed on
  operational database errors: administrator, library, and membership lookups
  now propagate errors into the event feed's retryable HTTP 500 path. Route
  regressions inject each inner-read failure and verify the same cursor later
  delivers its owner-visible event. `mise run check` passed (605 XCTest tests,
  34 Swift Testing tests, SwiftLint, web, and Tauri checks); the related
  multi-user plan remains active through renewed implementation review.

- 2026-08-30: comm-000540 changes TASK-408 opaque event cursors from
  destructive delivery to replay-safe successor delivery. A request cursor
  retains its prepared batch until its returned successor is used; retries and
  overlapping same-cursor polls replay the same owner-visible batch, and later
  events queue on the successor. HTTP-level dropped-response and concurrent
  same-cursor regressions cover the transport boundary. Verification passed:
  focused event-feed suites (24 XCTest tests), eight consecutive delivery-retry
  runs, `mise exec -- swift test` (612 XCTest and 34 Swift Testing tests),
  `mise run lint` (two pre-existing non-serious warnings), `mise run build`,
  `mise run check`, and `git diff --check`.

- 2026-08-30: comm-000542 preserves replay-safe delivery while rechecking
  current authorization for every retained batch. A replay after library-access
  revocation omits the cached metadata; an operational authorization-read error
  returns HTTP 500 without consuming the batch, and a later same-cursor retry
  returns the original owner-visible event. Focused event-feed suites (26
  XCTest tests), eight repeated replay-authorization runs, the complete Swift
  suite (614 XCTest and 34 Swift Testing tests), lint, build, complete
  repository checks, and `git diff --check` were run.

- 2026-08-30: Follow-up to comm-000546 makes concurrent long polls for the
  same TASK-408 cursor wait independently. Publishing one owner-visible event
  wakes every registered request; the first prepares the retained delivery and
  the others replay the identical event batch and successor cursor. The HTTP
  regression verifies two active same-cursor polls before publication. The
  completed multi-user plan status now identifies the latest accepted
  comm-000542 event-delivery milestone. Verification passed: focused event-feed
  suites (26 XCTest tests), eight repeated pre-publication overlap runs,
  `mise run check` (614 XCTest and 34 Swift Testing tests, SwiftLint with two
  pre-existing non-serious warnings, web, and Tauri checks), and `git diff
  --check`.

- 2026-08-30: comm-000550 closes translation false completion when a source
  note appears during provider execution. Completion now transactionally
  revalidates source/destination library equality and every current source
  note's output; an incomplete set refreshes and continues instead of storing
  `completed`. `AITranslationTests` deterministically inserts a source during
  invocation and verifies both outputs before completion. TASK-M06 is rechecked
  after focused, repeated, full Swift, lint, build, complete repository, and
  diff verification pass.

- 2026-08-30: comm-000555 hardens the shipped multi-user boundary without
  starting browser-login backlog work. Scoped non-admin and unauthenticated
  callers cannot manage accounts or access the global auto-action control
  plane; unscoped local and enabled administrator operation remains available.
  Tag removal authorizes its note or notebook before assignment policy checks,
  preventing foreign protected-tag status oracles. Focused AppCore, CLI, and
  GraphQL adversarial regressions cover the repaired paths. Verification
  passed: focused `NoteUserTests`, `NoteLibraryEnforcementTests`,
  `AutoActionTests`, `NoteGraphQLControlPlaneSecurityTests`, and
  `CommandCLITests` (69 XCTest and 18 Swift Testing tests); `mise run check`
  (621 XCTest and 35 Swift Testing tests, SwiftLint with two pre-existing
  non-serious warnings, web, and Tauri checks); and `git diff --check`.

- 2026-08-31: comm-000557 retains JWT scope through `kaiba auth token issue`
  and adds the same enabled-administrator-or-unscoped-local-operator check at
  the `NoteService.issueAuthToken` transaction boundary. Public individual
  account lookups now return only the caller's own record for scoped non-admin
  and unauthenticated principals; module-internal lookup helpers keep verified
  login and token-resolution flows independent of public account enumeration.
  Ordinary and agent JWT CLI regressions reject administrator-token issuance
  and chained account creation; service regressions cover foreign id/email
  lookups and direct normal-token issuance. Focused
  `NoteUserTests|NoteServiceAuthTokenTests|CommandCLITests|EmailLoginTests`
  passed (35 XCTest and 18 Swift Testing tests), and lint/build passed with two
  pre-existing non-serious SwiftLint warnings; `mise run check` passed (622
  XCTest and 35 Swift Testing tests, SwiftLint, web, and Tauri checks), and
  `git diff --check` passed.

- 2026-08-31: comm-000562 follows the multi-user control-plane review without
  starting remaining browser-login work. API-client management is now limited
  to enabled administrators and the unscoped local operator; library policy
  and membership writes are limited to those principals or library owners.
  Leased auto-action writes are fenced by their active outbox token, with a
  stale-worker regression. Focused Swift security verification, full
  `mise exec -- swift test --quiet` (625 XCTest and 36 Swift Testing tests),
  `mise run lint` (two pre-existing non-serious warnings), `mise run build`,
  `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000564 completes the latest Step 6 revision: API-client
  listing now performs its authorization and global query in one transaction,
  with disabled-administrator refusal coverage;
  leased chat streaming and cancellation terminalization retain the active
  dispatch fence. A blocked-provider lease-reclaim regression verifies that a
  stale worker cannot publish chunks, finish a stream, or persist its reply.
  Focused `AgentChatDispatchSecurityTests|NoteUserTests|NoteLibraryMemberTests|CommandCLITests`
  verification passed (45 XCTest and 19 Swift Testing tests); `mise exec --
  swift test --quiet` passed (627 XCTest and 36 Swift Testing tests), as did
  `mise run lint` (two pre-existing non-serious warnings), `mise run build`,
  and `mise run check`.

- 2026-08-31: comm-000566 closes the remaining Step 6 self-review races.
  The API-client listing transaction now has a deterministic interleaved
  administrator-demotion attempt proving authorization and the global query
  cannot be split. Leased chat streams register their outbox lease with the
  stream hub before execution, and the hub accepts chunks plus `answered`,
  `failed`, and `cancelled` terminals only from the current lease. A blocked
  worker regression reclaims the lease after validation but before stream
  admission; stale chunks and every terminal status are rejected. Focused
  `AgentChatDispatchSecurityTests|AgentReplyStreamHubTests|NoteUserTests|NoteLibraryMemberTests|CommandCLITests`
  passed (54 XCTest and 19 Swift Testing tests), and full
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

- 2026-08-31: comm-000570 binds every deferred terminal acknowledgement to
  the generation that returned it and keeps retry cursors monotonic. A failed
  generation's delayed acknowledgement cannot evict an answered retry, and a
  failed-generation cursor resumes at the retry's first chunk. Deterministic
  zero-retention overlap and cursor-continuity regressions accompany the
  focused and complete verification evidence.

- 2026-08-31: comm-000570 verification passed: focused
  `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests` ran 22 XCTest
  tests, and the retry-generation regressions passed eight consecutive times.
  `mise exec -- swift test --quiet` passed (632 XCTest and 36 Swift Testing
  tests); `mise run lint` passed with two pre-existing non-serious warnings;
  `mise run build` and `mise run check` passed.

- 2026-08-31: comm-000572 preserves failed retry cursor continuity across
  terminal retention eviction. The stream hub saves an evicted failed
  generation's cursor base and consumes it when the higher-attempt retry starts;
  a pressured-retention regression resumes that retry with the failed cursor.
  Focused `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests` passed (23
  XCTest tests); all three retry-generation regressions passed eight consecutive
  runs. `mise exec -- swift test --quiet` passed (633 XCTest and 36 Swift
  Testing tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build`, `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000574 replaces unbounded failed-stream cursor tombstones
  with opaque, generation-encoded retry cursors. Failed-terminal eviction
  retains no per-turn cursor state; a mismatched prior-generation cursor safely
  starts the retry at its first chunk. Deterministic pressure coverage evicts
  128 distinct failed streams and then resumes the first turn's retry using its
  original failed cursor. Focused
  `mise exec -- swift test --filter 'AgentReplyStreamHubTests|AgentChatDispatchSecurityTests'`
  passed (24 XCTest tests), and the pressure regression passed eight consecutive
  runs. `mise exec -- swift test --quiet` passed (634 XCTest and 36 Swift
  Testing tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build`, `mise run check`, and `git diff --check` passed.

- 2026-08-31: comm-000576 makes the stream-cancellation regression
  deterministic. `AgentReplyStreamHub` exposes an actor-owned test handshake
  for deferred-response registration, replacing the timing-based readiness
  loop before cancellation. Focused `AgentReplyStreamHubTests|AgentChatDispatchSecurityTests`
  passed (24 XCTest tests), the repaired regression passed 20 consecutive
  runs, and full `mise exec -- swift test --quiet` passed (634 XCTest and 36
  Swift Testing tests); `mise run lint` (two pre-existing non-serious warnings),
  `mise run build`, and `mise run check` passed.

- 2026-08-31: comm-000581 closes the final post-poll authorization windows.
  `GET /note/events` reauthorizes every prepared event after suspended-request
  credential reauthentication and before serialization; an operational failure
  returns 500 without advancing the prepared cursor. `GET /note/agent-stream`
  admits terminal delivery only after its final turn/library authorization,
  following any deferred acknowledgement wait. Deterministic route tests revoke
  library access during each respective suspension and prove no event metadata
  or reply chunks are returned. Focused server security suites passed (49
  XCTest tests); `mise run lint` passed with two pre-existing non-serious
  warnings, and `mise run check` passed (Swift, web, and Tauri verification).

- 2026-08-31: comm-000585 makes control-plane authorization and protected
  reads or mutations atomic. Account and administrator lists run their
  authorization plus query in one immediate transaction; auto-action retry
  selection and stale-lease recovery use the same pattern. The account-library
  membership reader now rejects foreign and unauthenticated scopes before
  resolving its target. Token-principal and separate-connection demotion
  regressions passed with
  `mise exec -- swift test --filter 'NoteLibraryMemberTests|NoteUserTests|AutoActionTests'`
  (62 XCTest tests). `mise run check` passed (639 XCTest, 36 Swift Testing,
  156 Bun, 34 Vitest, SwiftLint, web build, and Tauri checks); SwiftLint reports
  only its two pre-existing non-serious warnings.

- 2026-08-31: comm-000589 applies the same library-reach contract to CLI
  notebook moves. A JWT-scoped caller cannot use `library move` to probe or
  select an unreachable protected destination; hidden and missing destinations
  return the same missing-library result, and refusal preserves the notebook's
  original library. AppCore and ordinary-JWT CLI regressions cover this
  boundary. `mise run check` passed (640 XCTest and 37 Swift Testing tests,
  SwiftLint with two pre-existing non-serious warnings, web, and Tauri checks);
  `git diff --check` passed.

- 2026-08-31: comm-000594 applies current library reach to tag-comment reads
  and tag-detail aggregates, including a selected-library scope. AppCore and
  GraphQL regressions prove unauthenticated and revoked-membership principals
  cannot recover protected comment bodies, titles, or counts. Translation
  outputs now record a SHA-256 source-content version; transactional output
  writes and completion only accept each source's current version, and a
  deterministic concurrent body-edit regression re-translates the changed
  source before marking the run complete. The scoped orphan-file documentation
  was corrected. Focused
  `mise exec -- swift test --filter 'NoteTagDetailTests|NoteGraphQLTagDetailTests|AITranslationTests'`
  passed (35 XCTest tests), the source-edit regression passed eight consecutive
  runs, `mise run lint` passed with two pre-existing non-serious warnings,
  `mise run build` passed, `mise run check` passed (643 XCTest and 37 Swift
  Testing tests, 156 Bun tests, 34 Vitest tests, web build, and Tauri checks),
  and `git diff --check` passed.

- 2026-08-31: comm-000596 closes stale translation-output retention when a
  source changes after its older output committed but before completion. The
  translation write transaction replaces obsolete same-source versions, and
  completion accepts exactly one current source-content hash per remaining
  source. `AITranslationTests` adds a deterministic post-write edit regression;
  it passed eight consecutive runs. Focused
  `NoteTagDetailTests|NoteGraphQLTagDetailTests|AITranslationTests` passed (36
  XCTest tests); `mise run lint` passed with two pre-existing non-serious
  warnings; `mise run build` passed; and `mise run check` passed (644 XCTest,
  37 Swift Testing, web, and Tauri checks).

- 2026-08-31: comm-000600 treats a translation source deleted after provider
  invocation as a stale snapshot, refreshing to complete only against the
  remaining current sources. It also applies current reachable-library IDs to
  `listAgentConversations` before ordering and `LIMIT`, so revoked protected
  conversations cannot consume a page or make hydration fail. Deterministic
  provider-boundary deletion and revoked-membership regressions passed. Focused
  `mise exec -- swift test --filter 'AITranslationTests|AgentChatLibraryBoundaryTests' --quiet`
  passed (26 XCTest tests); `mise run lint` passed with two pre-existing
  non-serious warnings; `mise run build` passed; `mise run check` passed (646
  XCTest and 37 Swift Testing tests, web and Tauri checks); and `git diff --check`
  passed.

- 2026-08-31: comm-000604 closes the recovered answered-chat stream gap. An
  answered turn stores the immutable provider-context library, so a recovered
  active lease emits its `answered` terminal stream state without a second
  provider invocation and without weakening post-move library visibility. The
  deterministic `AgentReplyStreamHub` regression reclaims the lease after
  answer persistence but before terminal admission, then proves the actual
  recovered dispatcher returns `done=true`, `status=answered`. Focused
  `AgentChatDispatchSecurityTests|AgentReplyStreamHubTests` passed (25 XCTest
  tests); lint and build passed with the existing two non-serious lint warnings;
  full Swift verification passed (647 XCTest and 37 Swift Testing tests), as
  did `mise run check` and `git diff --check`.

- 2026-08-31: comm-000606 makes the legacy malformed-auto-action filter
  regression deterministic. Auto-action dispatch completion is concurrent, so
  the test now requires exactly the expected action IDs without assuming their
  completion order. The focused regression passed 20 consecutive runs;
  `AutoActionTests|AgentChatDispatchSecurityTests|AgentReplyStreamHubTests`
  passed (50 XCTest tests); `mise run check` passed (647 XCTest, 37 Swift
  Testing, 156 Bun, and 34 Vitest tests; web build and Tauri checks); and
  `git diff --check` passed. SwiftLint retains two pre-existing non-serious
  warnings.

- 2026-08-31: comm-000610 reconciles the completed multi-user plan and design
  specification with the shipped tag-detail library enforcement. Comments,
  aggregate counts, and tag-memo lookup apply current reachable-library scope;
  tag-detail is removed from the deferred list, leaving sharing-era attribution
  and per-user long-term memory as the two multi-user items still open. Focused
  tag-detail tests, lint, the repository gate, and `git diff --check` are
  recorded after this documentation-only revision.

- 2026-08-31: comm-000614 reopened and rechecked shipped TASK-408 stream
  delivery. A nonterminal snapshot now retains an in-flight delivery
  obligation through second authentication and final owner/library
  authorization. If the stream finishes while that response is suspended, an
  elapsed grace deadline is restarted after the response is accepted or
  rejected, preserving the terminal tail for its successor cursor. The
  deterministic route regression covers chunk wakeup, suspended second
  authentication, stream completion, grace expiry, retention pressure, and
  terminal-tail recovery. Focused stream tests (15 XCTest tests), eight
  consecutive regression runs, lint, build, `mise run check` (648 XCTest, 37
  Swift Testing, 156 Bun, and 34 Vitest tests; SwiftLint, web build, and Tauri
  checks), and `git diff --check` are recorded with the multi-user plan.

- 2026-08-31: comm-000616 adds an actor-owned grace-expiry witness to the
  comm-000614 route regression. Retention pressure and authentication release
  now occur only after grace expiry has observed the active delivery obligation,
  proving the exact tail-recovery interleaving before TASK-408 is rechecked.

- 2026-08-31: comm-000623 records the related bounded stream-payload and
  terminal final-attempt recovery remediation in the completed multi-user plan.
  It adds no browser-login work and preserves the reconciled plan boundary.

- 2026-08-31: comm-000630 rechecks TASK-408 stream delivery and durable
  workflow reliability. Live leased chat chunks are ordered and lease-fenced
  during provider execution rather than deferred until turn completion;
  provider relay and ACP stdout retention are bounded to 256 chunks and
  256 KiB. Translation source reconciliation has bounded rounds, provider
  calls, and elapsed time, failing retryably on sustained churn. Focused Swift
  regressions and the complete `mise run check` gate passed (659 XCTest and 37
  Swift Testing tests; SwiftLint, web, and Tauri checks).

- 2026-08-31: comm-000632 corrects the related translation elapsed-time
  evidence. The reconciliation deadline is enforced before and after every
  provider call within a round, and a deterministic injected-clock regression
  proves expiry during the first call fails retryably without starting a second
  call. Focused Swift tests passed (62 XCTest tests); `mise run lint` passed
  with two pre-existing non-serious warnings; the regression passed eight
  consecutive runs; `mise run check` passed (660 XCTest and 37 Swift Testing
  tests, SwiftLint, web, and Tauri checks); and `git diff --check` passed. No
  browser-login work was added.

- 2026-08-31: comm-000636 preserves an existing tag memo's library when the
  final tagged source disappears. Only exactly one reachable source library
  may rehome the memo; AppCore and GraphQL regressions retain a protected memo
  through the ordinary default-user path and verify unauthenticated access is
  refused. Focused related tests passed (83 XCTest tests), the two new
  regressions passed eight consecutive runs, `mise run lint` passed with two
  pre-existing non-serious warnings, `mise run build` passed, and `mise run
  check` passed (662 XCTest and 37 Swift Testing tests, SwiftLint, web, and Tauri checks). No
  browser-login work was added.

- 2026-08-31: comm-000641 updates the related multi-user implementation only.
  Final recovery preserves committed chat and translation results before
  disabled-principal cancellation logic, and the agent-gateway adapter now
  bounds stdin/process completion with cancellation, SIGTERM, and SIGKILL.
  Disabled-after-commit and uncooperative-process regressions pass; no
  browser-login backlog work was added. The completed multi-user plan records
  focused verification, repeated gateway termination checks, lint, build, and
  the passing full repository gate after this plan update.

- 2026-08-31: comm-000643 addresses the gateway-process self-review only.
  The adapter now isolates each gateway process group, terminates the full
  group on deadline or cancellation, and protects Linux's detached stdin
  writer from SIGPIPE. Cancellation and descendant-termination regressions,
  Linux POSIX interface typechecking, and the repository verification gate are
  recorded in `impl-plans/completed/multi-user.md`; no browser-login scope was
  added.

- 2026-08-31: comm-000645 completes the remaining gateway descendant-lifecycle
  revision. Process-group SIGKILL escalation no longer depends on direct-child
  completion, and nonblocking pipe finalization keeps descendant-held output
  descriptors within the invocation's bounded cleanup lifecycle. Regressions
  cover SIGTERM parent exit with an ignoring recorded descendant and normal
  direct-child exit with a descendant-held descriptor; the full gateway class
  passed (17 XCTest tests) and the new regressions passed eight consecutive
  runs. `mise run lint` passed with two pre-existing non-serious warnings, and
  `mise run check` passed (669 XCTest, 37 Swift Testing, 156 Bun, and 35 Vitest
  tests; SwiftLint, web build, and Tauri checks).

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

- 2026-08-31: comm-000649 completes deterministic verification of the related
  gateway cancellation cleanup. An injected cleanup-poll pacer proves that
  cancellation begins after direct-child completion and remains suspended at a
  paced poll while the scheduler can continue executing work, excluding a
  cancellation-induced busy spin. The gateway class passed (18 XCTest tests),
  the regression passed eight consecutive runs, and lint, build, and the full
  repository check passed; detailed evidence is recorded in
  `impl-plans/completed/multi-user.md`. No browser-login scope was added.

- 2026-08-31: comm-000654 hardens the served external-agent boundary and
  retry-stream recovery. `KaibaServerRuntime` now requests served execution:
  tool-capable coding vendors are rejected; permitted API vendors require an
  explicit credential variable and receive only that credential plus a small
  runtime allowlist in a temporary macOS filesystem sandbox. Newer leases now
  replace a nonterminal stream generation before publishing retry output,
  clearing stale chunks, library metadata, and delivery obligations while
  signalling client resync. Sentinel-secret/read/write and partial-output
  recovery regressions passed with the focused security suites; `mise run
  lint` passed with two pre-existing non-serious warnings and `mise run check`
  passed. No browser-login scope was added.

- 2026-08-31: comm-000656 completes the follow-up served-agent hardening:
  gateway filesystem read access is exact-executable rather than parent-folder
  recursive, server reconciliation preflights served restrictions before it
  enables auto-actions, and served gateway diagnostics are suppressed before
  durable AI state can retain provider credentials or local paths. Focused and
  complete verification passed: the focused suites ran 97 XCTest tests,
  `mise run lint` retained only two pre-existing non-serious warnings, full
  Swift tests passed (678 XCTest and 37 Swift Testing tests), and `mise run
  check` passed (Swift, SwiftLint, web, and Tauri checks).

- 2026-08-31: comm-000658 closes the served credential-name and late-failure
  boundaries. Factory and reconciliation preflight now reject malformed or
  sandbox-reserved credential variable names (`HOME`, `TMPDIR`, XDG runtime
  keys, `PATH`, `LANG`, and `LC_ALL`) before constructing the isolated
  environment; the isolated credential assignment cannot create duplicate
  dictionary keys. Served invocation failures now convert missing-binary,
  workspace, and process-start diagnostics to fixed safe errors before chat or
  translation persistence. Regressions cover `HOME`/`PATH` factory,
  reconciliation, and invocation collisions plus removal of a configured
  binary after preflight with chat and translation state checks. The focused
  gateway/reconciliation/chat/translation suite passed 80 XCTest tests;
  SwiftLint passed with two pre-existing non-serious warnings, and `mise run
  check` passed.

- 2026-08-31: comm-000662 separates ordinary translation work from source-set
  churn accounting. `AITranslationService` now processes every note in its
  initial stable snapshot before reconciliation rounds, provider-call, and
  elapsed-time budgets begin; a 129-note stable translation completes through
  the queued workflow on its first outbox attempt, while sustained source churn
  remains bounded and retryable. AI9 now documents `cancelled` as a terminal
  safety state whose recovery never resumes provider work. `AITranslationTests`
  passed (22 XCTest tests); the focused adjacent security suite passed (81
  XCTest tests); SwiftLint retained only two pre-existing non-serious warnings;
  and `mise run check` passed (Swift, SwiftLint, web, and Tauri checks).

- 2026-08-31: comm-000666 updates the shared control-plane and event-client
  boundary evidence. Both global auto-action listing operations authorize and
  select inside one immediate transaction, preventing concurrent administrator
  demotion from observing global configuration or dispatch records. The event
  client acknowledges a server revision only after subscriber callbacks finish,
  preserving retained-batch replay on callback failure. Focused Swift and Bun
  regressions cover the demotion and replay contracts. Final `mise run check`
  passed with 685 XCTest, 37 Swift Testing, 157 Bun, and 35 Vitest tests;
  SwiftLint retained only two pre-existing non-serious warnings.

- 2026-08-31: comm-000668 rejects caller-authored `kaibaChat` note metadata
  at the public GraphQL creation boundary. The agent-chat replay regression
  now attempts a complete pending-turn payload in a genuine conversation and
  verifies it cannot satisfy the idempotency lookup; an internally created
  genuine turn remains replayable. `AgentChatGraphQLTests` passed (23 XCTest
  tests), SwiftLint retained only two pre-existing non-serious warnings, and
  `mise run check` passed.

- 2026-08-31: comm-000673 adversarial follow-up adds 429 long-poll admission
  for event-cursor and reply-stream waiters, verifies that reply-stream IDs
  name agent-chat turns, and bounds accepted HTTP connections. Model catalog
  discovery is now cached and single-flight after authorized idempotent replay.
  Translation continuation and shared provider execution admission are still
  pending, so no completion criterion was changed.

- 2026-08-31: comm-000675 closes the remaining adversarial availability and
  cost-control findings. Shared global/per-principal provider admission now
  applies backpressure to queued work and model catalog discovery. Translation
  initial work now persists a continuation and runs under 128-call and elapsed
  budgets per durable dispatch; a deferred chunk preserves the retry budget.
  Direct pressure tests cover event/reply waiter caps, non-chat stream refusal,
  exact HTTP connection capacity, catalog overload, and durable 129-source
  continuation. Repository-gate evidence remains pending its stable rerun.

- 2026-08-31: comm-000677 bounds translation database and memory work as well
  as provider calls. Translation snapshots now use a durable source cursor and
  keyset `LIMIT 128` source/output queries; cursor-tail completion avoids a
  full notebook scan and restarts safely when source content changes or a new
  note appears. The connection-capacity regression now holds 256 live TCP
  connections, verifies HTTP 429 for connection 257, releases the held
  requests, and verifies a replacement connection receives HTTP 200. Focused
  `AITranslationTests|AutoActionTests|AgentChatGraphQLTests|NoteChangeFeedOverflowTests|AgentReplyStreamHubTests|AgentReplyStreamRouteValidationTests|KaibaLocalHTTPServerCapacityTests`
  passed (100 XCTest tests); the live connection test passed three consecutive
  runs; `mise run lint`, `mise run build`, and `git diff --check` passed. The
  full `mise run check` remains a Step 6 blocker: it repeatedly hangs in the
  complete suite at `AgentGatewayCLIInvokerTests/testInvokerForceKillsGatewayThatIgnoresSIGTERM`,
  although the standalone 25-test gateway class passes.

- 2026-08-31: comm-000679 resolves the exact-page translation and stale
  snapshot findings. Exact 128- and 256-source direct and queued workflows now
  complete through the final empty keyset page, and durable source revisions
  detect deterministic same-timestamp post-output edits and deletions. The
  leader-only SIGTERM-ignore regression no longer creates an unrelated
  background process; focused translation and gateway verification passed.
  `mise run check` remains required before this Step 6 revision can return to
  independent review.

- 2026-08-31: comm-000679 complete verification passed. `mise run check`
  completed with 698 XCTest and 37 Swift Testing tests, SwiftLint with two
  pre-existing non-serious warnings, web checks/build, and Tauri checks. The
  route-authorization fixture now uses genuine scoped chat turns, matching the
  enforced non-chat stream rejection and making its delivery handshake finite.

- 2026-08-31: comm-000681 closes the agent-chat source-revision gap identified
  during translation completion review. The assistant-body update records a
  same-transaction, non-undoable AI note action so translated conversations
  restart after a post-output reply commit even when the source timestamp is
  unchanged. Deterministic translation, pagination, chat, and library-boundary
  coverage passed; repository-gate verification is recorded with this Step 6
  remediation.

- 2026-08-31: comm-000685 corrects AI9 direct-pagination reconciliation
  accounting. Stable keyset pages advance without consuming the eight-round
  source-churn budget; only a changed durable source revision or cursor reset
  is charged. A direct 1,024-source regression covers eight complete
  128-source pages plus the empty completion page. AI9 now records bounded
  durable pagination and the revision-only reconciliation contract.
  `AITranslationTests|AITranslationPaginationTests` passed 30 XCTest tests;
  SwiftLint retained two pre-existing non-serious warnings; and `mise run
  check` passed 700 XCTest and 37 Swift Testing tests plus web and Tauri
  checks.

- 2026-08-31: comm-000687 replaces the translation source token's prunable
  `note_action_log` lookup with a non-prunable per-notebook revision
  written transactionally with every notebook action. The deterministic
  low-retention regression mutates an already translated source, prunes its
  action record with later translation outputs, and verifies retranslation
  before completion.

- 2026-08-31: comm-000692 remediation adds bounded incomplete-request
  deadlines to the local HTTP listener. A connection that cannot finish its
  headers or declared body is cancelled and removed, preserving the global
  256-connection admission limit for later complete requests. Gateway
  descendant cleanup now distinguishes pre-reap leader termination from
  post-reap process-group cleanup so a reused PID is never signalled. Focused
  gateway and HTTP-capacity verification passed (28 XCTest tests), as did
  SwiftLint with two pre-existing non-serious warnings and `mise run check`.
  Renewed review remains required.

- 2026-08-31: comm-000694 remediation makes the incomplete-request timeout an
  absolute deadline: partial header/body progress no longer resets it. Gateway
  lifecycle state is marked immediately after `waitpid` and before completion
  publication; timeout/output callbacks no longer signal a positive PID after
  that boundary. Deterministic lifecycle and socket-capacity regressions cover
  both interleavings. Focused coverage passed 29 XCTest tests; the complete
  Swift suite passed 704 XCTest and 37 Swift Testing tests; and `mise run
  check` passed with only two pre-existing non-serious SwiftLint warnings.
  Renewed Step 6 self-review and Step 7 review remain required.

- 2026-08-31: comm-000696 synchronizes the final gateway waitpid/reap boundary
  shared by timeout, output-limit, and cancellation termination callbacks.
  Pre-reap group signaling now performs nonblocking `waitpid` and signal
  selection under one lifecycle lock, publishing completion only after the
  reaped state is authoritative. A deterministic lifecycle test pauses after
  `waitpid` returns but before publication, triggers timeout and SIGKILL grace
  escalation, and proves no process-group signal is emitted. The completed
  multi-user plan records the companion absolute-request-deadline coverage.
  Focused lifecycle/capacity coverage passed 30 XCTest tests; `mise run check`
  passed 705 XCTest and 37 Swift Testing tests, 157 Bun tests, 35 Vitest tests,
  SwiftLint with two pre-existing non-serious warnings, web build, and Tauri
  checks.

- 2026-08-31: comm-000699 strengthens the exact waitpid-to-publication
  regression. The test now holds the scheduled grace-period SIGKILL callback,
  confirms the leader has reached the paused pre-publication reap boundary,
  then releases both gates and asserts that no SIGKILL is emitted after the
  original timeout SIGTERM. The prior fixture exited before timeout and did
  not exercise delayed escalation. Focused lifecycle/capacity coverage passed
  30 XCTest tests and the exact regression passed eight consecutive runs.
  `mise run lint` passed with two pre-existing non-serious warnings. The
  post-revision `mise run check` gate stalled without failure output and was
  interrupted after 654 seconds, so a renewed complete gate remains required.

- 2026-08-31: comm-000701 replaces the fixture-issued SIGKILL with a
  deterministic SIGTERM handler. The fixture becomes ready only after its
  handler is installed, records receipt of the production timeout SIGTERM,
  exits through that handler, pauses after `waitpid`, and waits for the real
  scheduled grace callback before proving that only the initial SIGTERM was
  emitted. Gateway children now start with SIGTERM restored and unblocked.
  Focused gateway/lifecycle/capacity coverage passed 30 XCTest tests, the
  corrected regression passed eight consecutive runs, and clean `mise run
  check` verification passed 705 XCTest and 37 Swift Testing tests, 157 Bun
  tests, 35 Vitest tests, SwiftLint with two pre-existing non-serious
  warnings, web build, and Tauri checks.

- 2026-08-31: comm-000703 makes the zero-retention terminal-stream
  cancellation regression deterministic. Deferred-response registration
  remains the ordering handshake; the ordinary poll deadline is now a
  60-second non-interfering safety bound instead of a competing two-second
  timer. The associated lifecycle test now waits for the observed post-reap
  timeout attempt rather than a fixed delay. Twenty repeated stream runs,
  eight repeated lifecycle runs, focused combined tests (22 XCTest tests),
  SwiftLint with two pre-existing non-serious warnings, and `mise run check`
  passed (705 XCTest, 37 Swift Testing, 157 Bun, 35 Vitest, web build, and
  Tauri checks).

- 2026-08-31: comm-000707 separates stable translation pagination from
  source-revision reconciliation in queued dispatches. Stable continuation
  still defers and refunds its lease attempt; a changed source now records a
  retry-consuming failure, so sustained churn cannot invoke the provider past
  the three-attempt durable budget. Gateway post-reap cleanup now runs even
  when descendants closed inherited stdout and stderr, while retaining the
  synchronized pre-reap authority and no delayed post-reap PID escalation.
  New queued-churn and closed-descriptor descendant regressions passed in the
  60-test focused translation/gateway suite; the descendant regression passed
  eight consecutive isolated runs. `mise run lint` retained two pre-existing
  non-serious warnings; `mise run check` passed 707 XCTest, 37 Swift Testing,
  157 Bun, and 35 Vitest tests plus web build and Tauri checks. Renewed review
  remains the only implementation gate.

- 2026-08-31: Step 6 revision for review finding
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-finding-1`
  replaces post-reap gateway-PGID signaling with a dedicated direct-child
  witness. The witness leads the invocation group and is deliberately held
  unreaped until SIGTERM, grace-period SIGKILL, and final cleanup complete, so
  its numeric group ID cannot be recycled between a liveness check and signal.
  Lifecycle regressions prove normal exit, timeout after leader reap, scheduled
  escalation after `waitpid`, and a closed-descriptor SIGTERM-ignoring
  descendant all signal the witness group rather than the reaped gateway. The
  ownership completion criterion is preserved; browser-login deliverables
  remain untouched. Focused translation/token/gateway/lifecycle/capacity
  verification passed 90 XCTest tests; `mise run lint` passed with three
  non-serious warnings; `mise run build`, `mise run check` (707 XCTest, 37
  Swift Testing, 157 Bun, and 35 Vitest tests), and `git diff --check` passed.

- 2026-08-31: Step 6 follow-up resolves
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-finding-2`.
  Witness-backed cleanup now polls the still-owned process group through
  SIGTERM grace and final SIGKILL before normal completion, timeout, or
  post-exit cancellation returns. The new un-injected production regression
  cancels only after post-exit cleanup begins and proves `CancellationError`
  is delivered after its SIGTERM-ignoring descendant is gone. No browser-login
  backlog work was added. Focused translation/token/gateway/lifecycle/capacity
  verification passed 91 XCTest tests; `mise run lint` passed with three
  non-serious warnings; `mise run build`, `mise run check` (708 XCTest, 37
  Swift Testing, 157 Bun, and 35 Vitest tests), and `git diff --check` passed.

- 2026-08-31: Step 6 revision resolves the descendant-cleanup defect found in
  comm-000715 against authoritative prior finding
  `codex-design-and-implement-review-loop-session-50-step6-implement-self-review-attempt-1-finding-1`.
  Process-group membership now excludes the unreaped ownership witness: clean
  post-reap exits reap immediately without grace latency or SIGKILL, while
  final escalation waits until every descendant, including an adopted zombie,
  disappears before releasing cancellation or normal completion. Production
  regressions cover the no-descendant fast path and cancellation waiting for a
  SIGTERM-ignoring descendant. Verified with `mise exec -- swift test --filter
  'AgentGatewayPostExitCancellationTests|AgentGatewayCLIInvokerTests|AgentGatewayCLIInvokerLifecycleTests' --quiet`
  (30 XCTest tests).

- 2026-08-31: Step 6 self-review follow-up resolves
  `codex-design-and-implement-review-loop-session-51-step6-implement-self-review-attempt-1-finding-1`
  and `codex-design-and-implement-review-loop-session-51-step6-implement-self-review-attempt-1-finding-2`.
  The post-reap state now distinguishes no descendants, live descendants,
  zombie-only descendants, and unavailable inspection. Zombie-only cleanup
  awaits disappearance without SIGKILL; unavailable `/proc` or `sysctl`
  inspection remains fail-closed, with Darwin retries for a changing process
  table. Deterministic lifecycle regressions cover both states. Verification:
  `mise exec -- swift test --filter
  'AgentGatewayPostExitCancellationTests|AgentGatewayCLIInvokerTests|AgentGatewayCLIInvokerLifecycleTests' --quiet`
  passed 32 XCTest tests; `mise run build` and `mise run lint` (three
  non-serious warnings) passed; `git diff --check` passed.
