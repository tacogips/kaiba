# Note API Authentication

**Status**: PARTIALLY SUPERSEDED — this plan predates the browser-driven login
revision of the spec (commit `3712644`) and was not updated with it. Phase 1
(SPA unauthenticated state, localStorage token) has shipped. The account/session
tasks below still describe the abandoned shape and must be reconciled with the
current spec before use:

- Accounts reuse the existing `users` table, not a new `auth_users` (TASK-401).
- The process credential is an HS256 JWT; `auth_sessions` and `ks_` tokens were
  never built (TASK-402, TASK-404 deferred).
- The browser handoff is `POST /note/login/start` + `/note/login/poll` with a
  secret `pollSecret`/`deviceCode`, an `auth_login_requests` pending row, and
  the `GET`/`POST` approval pair — none of which is planned below (supersedes
  TASK-403's `/note/login/email` + `/note/login/verify`).
- Still open per the spec's Safety rules: per-source rate limiting on
  `/note/login/start`, and the `--allow-unauthenticated` loopback guard is now
  implemented in `ServeCommand.parse`.

**Design Reference**: `design-docs/specs/note-api-auth.md`
**Decisions**: `design-docs/user-qa/note-api-auth.md`

## Purpose

The web viewer has no unauthenticated state: a 401 from the note API is shown
as a generic banner while the reader shell still renders `No notebooks yet.`,
and its `Retry` button re-sends the same unauthenticated request. Separately,
kaiba has no account model at all — only opaque API clients — so there is
nothing to log into and nothing to attach an external identity to.

This plan gives the viewer a real login surface, then gives kaiba its own
authentication server with email login and optional external IdP federation,
behind a seam that can later be switched wholesale to a hosted provider such as
Auth0.

## Deliverables

- [ ] SPA renders a login view instead of the reader shell when the API is
      unauthenticated, and clears the stored credential on 401.
- [ ] Credential survives a new tab and a browser restart.
- [ ] `mode: none` is impossible on a non-loopback bind.
- [ ] `GET /note/auth-info` reports the effective mode to the client.
- [ ] `server.auth` configuration selects the provider.
- [ ] Accounts, login codes, and sessions in the note store.
- [ ] Email login end to end, fail closed on unknown addresses.
- [ ] External IdP as a login method inside `builtin`.
- [ ] `oidc` mode as a full switch to a hosted provider.

## Phases

Phase 1 fixes the reported defect with no server change and is independently
shippable. Phase 2 makes the mode an explicit value and closes the
unauthenticated-bind hole. Phase 3 adds configuration. Phase 4 is kaiba's own
auth server. Phase 5 federates an external IdP into it. Phase 6 is the hosted
switch.

## Tasks

### TASK-101: Unauthenticated state in the app store

**Phase**: 1
**Parallelizable**: No

Add an explicit `auth: 'unknown' | 'authenticated' | 'unauthenticated'` state to
`web/src/state/appStore.tsx`. Classify `NoteTransportError` with
`kind === 'http'` and `status === 401` as `unauthenticated` instead of routing
it into `error` (`appStore.tsx:299-301`). Apply the same classification to the
note, notes, and search paths so any 401 converges on one state.

**Completion Criteria**:

- [ ] A 401 sets `auth: 'unauthenticated'` and leaves `error` empty.
- [ ] Non-401 failures still populate `error` exactly as today.
- [ ] Unit tests cover 401 versus network failure versus GraphQL result failure.

### TASK-102: Discard the stored credential on 401

**Phase**: 1
**Parallelizable**: Yes

Already implemented before this plan: the transport clears `kaiba-note-bearer`
on a 401 (`web/src/notes/client.ts`), with coverage in
`web/src/notes/client.test.ts` ("distinguishes HTTP failures and clears only
the CLI session bearer on 401"). Kept here for the record.

**Completion Criteria**:

- [x] A 401 clears the stored key exactly once per response.
- [x] Test asserts the key is absent after a 401.

### TASK-103: Login view replaces the reader shell

**Phase**: 1
**Parallelizable**: No
**Depends on**: TASK-101

Switch on the auth state in `web/src/views/ChatbookView.tsx` so that
`unauthenticated` renders a login view and the reader grid, panes, splitters,
and tree are not mounted (`ChatbookView.tsx:88-104`). The error banner keeps its
role for non-auth failures.

The Phase 1 login view targets `apiKey`: a field to paste a key issued by
`kaiba client issue --name <n>`, which stores it and re-runs `refreshCatalog`.
It also states how to obtain a registration URL, since that URL is single-use,
is printed only at startup, and expires in 300 seconds. TASK-303 replaces this
with a mode-driven view.

**Completion Criteria**:

- [ ] With auth required and no credential, no reader pane or notebook tree is
      in the DOM, and `No notebooks yet.` does not appear.
- [ ] Pasting a valid key loads the catalog without a page reload.
- [ ] Pasting an invalid key keeps the login view and reports the failure.
- [ ] Under `--allow-unauthenticated` the login view never renders.

### TASK-104: Persist the credential across tabs

**Phase**: 1
**Parallelizable**: Yes

Move the bearer from `sessionStorage` to `localStorage` in
`browserEnvironment()` (`web/src/notes/client.ts:700-709`). Keep the
`NoteClientEnvironment` seam so tests keep injecting a fake store; rename the
methods to storage-neutral names.

**Completion Criteria**:

- [ ] A registered browser reaches the reader in a new tab with no `?code=`.
- [ ] Existing client tests pass against the renamed seam.

### TASK-201: Loopback guard for unauthenticated serving

**Phase**: 2
**Parallelizable**: Yes

Refuse `--allow-unauthenticated` unless the bind host is loopback, in
`ServeCommand.run` before the listener starts (`ServeCommand.swift:61`).

**Completion Criteria**:

- [ ] `--host 0.0.0.0 --allow-unauthenticated` exits non-zero with a message
      naming the host.
- [ ] `127.0.0.1` and `localhost` are unaffected.
- [ ] Test covers both branches.

### TASK-202: Effective auth mode as a value

**Phase**: 2
**Parallelizable**: No

Replace the `allowUnauthenticated` boolean threaded through
`ServeCommand.Options`, `DeterministicServerRouteHandler`, and
`KaibaNoteFileHTTPRouter` with a `NoteAPIAuthMode` value. Keep the CLI flag as
the override that forces `none`. The startup line generalizes from
`auth=disabled (--allow-unauthenticated)` to `auth=<mode>`.

**Completion Criteria**:

- [ ] Boolean removed from `AppServer` and `AppCLI` signatures.
- [ ] Existing behavior for both current modes is unchanged.
- [ ] `swift test` passes.

### TASK-203: `GET /note/auth-info`

**Phase**: 2
**Parallelizable**: No
**Depends on**: TASK-202

Add an unauthenticated route in `ServerContracts.swift` returning the effective
mode, the available login methods, and the non-secret facts a login view needs.
Never include secrets.

**Completion Criteria**:

- [ ] Route answers 200 in every mode without credentials.
- [ ] `none` returns `{"mode":"none"}` and nothing else.
- [ ] Response carries no secret or environment-derived value.

### TASK-301: `server.auth` configuration

**Phase**: 3
**Parallelizable**: No
**Depends on**: TASK-202

Add a `server` section to `KaibaConfiguration`
(`Sources/AppCore/KaibaConfiguration.swift:3`) carrying `auth.mode` and
per-provider settings, with secrets referenced by environment variable name
only. The CLI flag wins over the file.

**Completion Criteria**:

- [ ] Decoding covers absent, partial, and unknown-mode files.
- [ ] An unknown mode fails startup with a clear message.
- [ ] `--allow-unauthenticated` overrides any configured mode.

### TASK-302: Mode-driven login view

**Phase**: 3
**Parallelizable**: No
**Depends on**: TASK-203, TASK-103

The SPA fetches `/note/auth-info` before deciding what to render and selects
the login surface from the reported mode and methods.

**Completion Criteria**:

- [ ] `apiKey` renders the paste field, `builtin` the email form, `oidc` the
      redirect button.
- [ ] `none` renders no login surface in any code path.
- [ ] A failed discovery fetch degrades to the paste field rather than a blank
      screen.

### TASK-401: Account, login code, and session storage

**Phase**: 4
**Parallelizable**: No
**Depends on**: TASK-301

Migration adding `auth_users`, `auth_login_codes`, and `auth_sessions` per the
design, plus a `NoteService+Auth` extension mirroring the shape of
`NoteService+APIClients.swift`. Codes and session tokens are stored only as
SHA-256 hashes.

**Completion Criteria**:

- [ ] Migration applies to a fresh store and to the current schema version.
- [ ] Email uniqueness is enforced on a normalized form.
- [ ] No raw code or raw token is ever written to the database or a log.
- [ ] Tests cover create, disable, and lookup.

### TASK-402: Built-in session authenticator

**Phase**: 4
**Parallelizable**: No
**Depends on**: TASK-401

A `NoteAPIAuthenticating` implementation validating `ks_` session tokens
against `auth_sessions`, honoring expiry and revocation, and updating
`last_seen_at`. `POST /note/logout` revokes the current session. `apiKey`
credentials keep working alongside it for CLI use. See open question P6 on
sliding expiry.

**Completion Criteria**:

- [ ] Valid, expired, revoked, and unknown tokens each behave correctly.
- [ ] A revoked session stops working on the next request.
- [ ] An `apiKey` credential still authenticates in `builtin` mode.

### TASK-403: Email login and delivery seam

**Status**: Done for the CLI and the service; the HTTP routes remain.

`auth_login_codes` (schema 12), `requestEmailLoginCode` /
`verifyEmailLoginCode` / `sendEmailLoginCode`, the `KaibaMailSending` seam with
`LogMailSender` as the default, and `kaiba auth login request|verify`. A
verified code yields the same JWT the CLI and agent hand-off use, so no second
session concept was needed.

`POST /note/login/email` and `POST /note/login/verify` are still outstanding —
only the CLI can drive the flow today.

**Completion Criteria**:

- [x] A code logs in exactly once and never after expiry.
- [x] Unknown and disabled addresses mint nothing and answer identically.
- [x] Attempt cap and per-account rate limit are enforced and tested.
- [x] Codes are stored only as salted hashes.
- [ ] HTTP routes for the flow.

### TASK-404: `kaiba auth` CLI

**Phase**: 4
**Parallelizable**: Yes
**Depends on**: TASK-401

`kaiba auth user add|list|disable` and `kaiba auth session list|revoke`, with
`--output json` like the rest of the CLI. This is the only way an account comes
into existence.

**Completion Criteria**:

- [ ] Adding, listing, and disabling accounts works against a real store.
- [ ] Help text is registered in `Sources/AppCore/Command.swift`.
- [ ] `design-docs/specs/command.md` and `README.md` document the commands.

### TASK-405: Email login in the SPA

**Phase**: 4
**Parallelizable**: No
**Depends on**: TASK-403, TASK-302

Two-step email form in the login view, storing the returned session token
through the same seam as the pasted key.

**Completion Criteria**:

- [ ] Request, verify, and failure paths each render a clear state.
- [ ] The stored session survives a reload and is cleared on 401.

### TASK-406: Resend mail sender

**Status**: Done.

`ResendGatewayCLIMailSender` spawns `resend-gateway-writer emails send`
(`tacogips/resend-gateway`), keeping the API key inside the gateway's own
resolution chain — explicit key, `RESEND_API_KEY`, then kinko — so it never
reaches kaiba's configuration or logs. Selected with
`kaiba auth login request --mail-sender resend --from <address>`.

**Completion Criteria**:

- [x] A configured sender delivers a code; verified live, `last_event:
      delivered`.
- [x] The API key never appears in a log line, a response, or an error — kaiba
      never holds it.
- [x] Unit tests use a stub sender and a failing binary, not a live account.
- [ ] Configuration (`server.auth.builtin.mail`) instead of CLI flags — waits
      on TASK-301.

### TASK-407: Server route for agent tokens

**Phase**: 4
**Parallelizable**: No
**Depends on**: TASK-402

The service can mint agent tokens (`issueAuthToken`, done) but no HTTP route
hands one out. Add an authenticated route that mints a short-lived token for
the *calling* session's user only — never for an arbitrary user id — so the
browser can pass one to an agent.

**Completion Criteria**:

- [ ] The route mints only for the caller's own account.
- [ ] TTL is bounded to minutes, not the CLI maximum.
- [ ] An unauthenticated call is refused.
- [ ] The token never appears in a log line.

### TASK-501: External IdP federation inside `builtin`

**Phase**: 5
**Parallelizable**: No
**Depends on**: TASK-402

Authorization Code + PKCE in the SPA against the configured issuer; kaiba
verifies the ID token against a cached JWKS, extracts the verified email, and
issues its own session for the matching enabled account. An address with no
account is refused.

**Completion Criteria**:

- [ ] Signature, issuer, audience, nonce, and expiry are all verified.
- [ ] An unknown or disabled address cannot obtain a session.
- [ ] JWKS caching survives key rotation.
- [ ] Tests use a local fixture issuer, not a live tenant.

### TASK-601: `oidc` mode

**Phase**: 6
**Parallelizable**: No
**Depends on**: TASK-501

Validate issuer-minted access tokens on every request with no kaiba session
layer, so a hosted provider can own identity outright.

**Completion Criteria**:

- [ ] Verification failures answer 401 without leaking issuer detail.
- [ ] Switching modes needs no code change, only configuration.
- [ ] `apiKey` still authenticates for CLI use.

## Progress Log

- 2026-08-16: Plan created from `design-docs/specs/note-api-auth.md`.
- 2026-08-16: Direction set — own auth server with passwordless email login,
  external IdP as a login method, hosted switch later. P1-P5 answered in
  `design-docs/user-qa/note-api-auth.md` (P5: Resend, deferred to TASK-406);
  P6 (session expiry) remains open and does not block Phase 1.
- 2026-08-17: Email login implemented end to end on the CLI and verified live
  through resend-gateway: user created, code mailed from `onboarding@resend.dev`
  (Resend reported `delivered`), the mailed code exchanged for a token, that
  token used to write and to read a per-user catalog, and the code refused on
  reuse. A request for an address with no account sent no mail and answered
  identically. 415 XCTest and 32 swift-testing tests pass.
  Fixed along the way: the attempt counter was being rolled back by the same
  transaction that rejected a wrong code, which defeated the guessing cap.
- 2026-08-16: Phase 1 complete. TASK-101 (auth state), TASK-103 (login view
  replacing the shell) and TASK-104 (localStorage) implemented; TASK-102 was
  already in place. `web/src/views/LoginView.tsx` added; the client seam
  renamed from `*SessionItem` to `*StoredItem` and moved to localStorage.
  Verified: tsc clean, eslint clean, 137 bun tests and 6 vitest tests pass
  (including a new `ChatbookView.integration.tsx` asserting the shell is absent
  on 401), and a CLI-issued key authenticates the note API against a live
  `kaiba serve`.
