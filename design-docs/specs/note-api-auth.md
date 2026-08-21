# Note API Authentication

**Status**: Partially implemented; revised for browser-driven login
**Supersedes in part**: `kaiba-note.md` ("HTTP Note API and Web Viewer")

## Purpose

Give kaiba its own authentication server with email-based login, keep external
identity providers usable as a login method, and allow the whole thing to be
switched to a hosted provider such as Auth0 later. Along the way, give the web
viewer a real unauthenticated state instead of rendering the reader shell
behind a generic error banner.

Signing in happens in a browser and is passwordless throughout: `kaiba auth
login` opens one, and the person proves their address with a mailed link or a
one-time code. Nothing in the product asks for, stores, or resets a password.
The terminal never becomes the login surface — it starts the login and receives
the token.

## Current State

Authentication today is a single boolean decided at process start.

- `Sources/AppCLI/ServeCommand.swift:136` — with `--allow-unauthenticated` the
  authenticator is `nil`; otherwise a `QRClientRegistrationAuthenticator` is
  installed.
- `Sources/AppServer/NoteAPIAuthenticating.swift:19` — `NoteAPIAuthenticating`
  is already a protocol with one method, so the server side is close to
  pluggable; only one implementation exists.
- `Sources/AppServer/QRClientRegistrationAuthenticator.swift:152` — a request
  with no bearer is rejected with 401 `note API requires a bearer token`.
- `Sources/AppCore/NoteService+APIClients.swift:84` — issued tokens are stored
  as SHA-256 hashes in `api_clients`. CryptoKit is already linked.

### What the registration URL is

`kaiba serve` prints a line such as
`registrationURL=http://127.0.0.1:8787/note/register?code=<code>` plus the same
value as a terminal QR code (`ServeCommand.swift:176-179`).

- `code` is 24 random bytes, URL-safe encoded
  (`QRClientRegistrationAuthenticator.swift:83`).
- It is held **in process memory only**
  (`NoteAPIRegistrationChallengeStore.shared`), is **single-use**
  (`removeValue` at `:131`), and expires after at most **300 seconds**
  (`:55`, `:76`).
- It is issued **once, at startup**. There is no way to mint another while the
  server runs.
- Opening the URL serves the SPA (`GET /note/register` falls through to
  index.html, `ServerContracts.swift:142`). The SPA reads `?code=`, POSTs
  `{code, displayName}` to `/note/register`, receives a bearer token `rn_...`,
  and stores it (`web/src/notes/client.ts:55-72`).

So the registration URL is a **one-time invite link that provisions an API
client**, not a login page. Nothing in the product can re-issue it, and there
is no page a "log in" link could point at. That is the root of the reported
defect.

### What has shipped since

Phase 4 landed partially, and the shipped shape differs from this document's
first draft in two ways worth stating before reading further.

- Accounts reuse the existing `users` table (`NoteStoreSchema.swift:449`)
  rather than a separate `auth_users`. It already carries `email`,
  `disabled_at`, and `is_admin`, and notebook ownership already points at it, so
  a parallel account table would have to be joined to it on every request for
  nothing.
- The credential a verified code returns is an HS256 JWT (`KaibaJWT.swift:60`),
  not an opaque `ks_` row, and `auth_sessions` was never built. The reasoning is
  recorded under "Are sessions JWT?" in `design-docs/user-qa/note-api-auth.md`:
  the CLI is a separate process that opens the store directly, so its credential
  has to be verifiable without a server round trip.

Shipped: `auth_login_codes` (`NoteStoreSchema.swift:470`),
`requestEmailLoginCode` / `verifyEmailLoginCode` / `sendEmailLoginCode`
(`NoteService+EmailLogin.swift`), the `KaibaMailSending` seam with
`LogMailSender` and `ResendGatewayCLIMailSender`, and
`kaiba auth login request|verify` (`CommandAuth.swift:26`).

Not shipped: any HTTP login route — `ServerContracts.swift:136` routes only
`/graphql`, `/note/register`, `/note/events`, and `/note/agent-stream` — and any
login surface in the SPA beyond a pasted API key
(`web/src/views/LoginView.tsx`).

So the flow today is entirely terminal-side and entirely local. `kaiba auth
login request` opens the SQLite store directly (`CommandAuth.swift:73`), mails a
six-digit code, and `verify` signs a JWT in process. The CLI is not a client of
anything, and a browser cannot log in at all.

## Problems

1. **No unauthenticated state in the SPA.** A 401 is funnelled into the generic
   `error` string (`web/src/state/appStore.tsx:299-301`) and rendered as a
   banner while the entire reader shell still mounts
   (`web/src/views/ChatbookView.tsx:88-92`), showing `No notebooks yet.`
   (`web/src/components/FileTreeTab.tsx:32`). "Not logged in" is
   indistinguishable from "empty store", and `Retry` re-sends the same
   unauthenticated request forever.
2. **The token is per-tab.** It is written to `sessionStorage`
   (`web/src/notes/client.ts:703-705`), so a new tab or a browser restart drops
   it, and the only recovery path (the startup code) has usually expired.
3. **No account model.** There is no user, no email, no session — only opaque
   API clients. Nothing to attach an external identity to.
4. **`--allow-unauthenticated` is unguarded.** No check ties it to a loopback
   bind, so `--host 0.0.0.0 --allow-unauthenticated` exposes the whole note
   store to the network with no warning.
5. **Login is a terminal transcription exercise.** The only working method is
   reading a six-digit code out of a mail client and retyping it into a shell.
   There is no browser path, so the SPA cannot log anyone in, and the CLI cannot
   log in to a server it does not share a filesystem with.

## Design

### Target shape

kaiba runs its **own authentication server** inside `kaiba serve`. It owns the
account records and the sessions. Login methods plug into it, and one of those
methods may be an external IdP. Later, the entire authenticator can be swapped
for a hosted provider without touching routing or the note store.

| Mode | Provider | Selection |
| --- | --- | --- |
| `none` | no authenticator | `--allow-unauthenticated`, loopback only |
| `apiKey` | `QRClientRegistrationAuthenticator` (current) | default until `builtin` ships |
| `builtin` | kaiba's own auth server: email login, optional IdP federation | config |
| `oidc` | tokens minted by an external issuer (Auth0), kaiba only validates | config |

Every mode is an implementation of the existing `NoteAPIAuthenticating`
protocol, selected where `ServeCommand.swift:136` builds the authenticator. The
route handlers do not change.

`apiKey` is kept in all modes as a non-interactive credential for CLI and
scripts (`kaiba client issue`). Machine access must not require a browser.

### Decisions

**The process credential is a JWT; browser sessions may be opaque rows.**
Revised from this document's first draft, which called for opaque sessions
everywhere. The CLI is a separate process that opens the store directly, and an
agent must be able to run `kaiba --jwt <token>` as the person who asked it to,
so that credential has to be verifiable without a server round trip: an HS256
JWT signed with a key generated on first use and held in `app_settings`
(`KaibaJWT.swift:60`). Revocation does not depend on expiry, because
verification re-reads the account and a disabled user's outstanding tokens stop
working at once. Opaque `auth_sessions` rows remain the right shape for a
browser session, where revoking one device without disabling the person is
worth a table; the two are not in conflict. JWT verification against an external
issuer appears only in `oidc` mode, where kaiba is the verifier and the issuer
holds the keys.

**Login is browser-first, with the token handed back by polling.** `kaiba auth
login` opens a browser and the CLI polls a pending-login row until the browser
approves it, rather than receiving the token on a loopback redirect. The
redirect is simpler, but it binds the browser to the CLI's machine, which
excludes signing in over `ssh` and leaves the email link with nowhere to deliver
its approval. Polling also gives one approval path that both the email link and
the six-digit code feed into, instead of two mechanisms that have to be kept in
agreement. Full flow under "Login flow (`builtin`, email)".

**Email login is passwordless.** The built-in method sends a one-time code (or
a link carrying it) to the account's address; the code is single-use, short
lived, rate limited, and stored only as a hash. This is a deliberate choice
over email + password: neither CryptoKit nor swift-crypto ships PBKDF2 or
Argon2 portably, CommonCrypto is Apple-only, and the project builds for Linux.
Passwordless removes the KDF question instead of answering it, and removes
password reset, breach exposure, and storage rules with it. Passwords can be
added later behind the same seam if a real need appears.

**Vapor is not adopted.** kaiba has one external package (`anydoc-swift`,
`Package.swift:15-17`) and a hand-written `KaibaLocalHTTPServer` over
Network.framework. Vapor would replace that entire layer and pull SwiftNIO into
a Homebrew-distributed CLI, and none of the above needs it: CryptoKit is
already linked and the sessions are opaque.

**Fail closed on accounts.** An address can log in only if an enabled
`auth_users` row exists for it. There is no self-signup and no first-visitor
claim. Accounts are created out of band with `kaiba auth user add --email`.

### Storage

Accounts are the existing `users` table (`NoteStoreSchema.swift:449`). It
already has `email` with a unique partial index, `display_name`, `created_at`,
`disabled_at`, and `is_admin`, and notebook ownership already references it.

- `auth_login_codes` — shipped (`NoteStoreSchema.swift:470`): `code_id`,
  `user_id`, `code_hash`, `attempts`, `created_at`, `expires_at`,
  `consumed_at`. Single use, capped at five attempts, at most three live per
  account.
- `auth_login_requests` — new, and the whole of the browser handoff:
  `request_id`, `user_code`, `approval_token_hash`, `user_id` (null until
  approved), `client_description`, `created_at`, `expires_at`, `approved_at`,
  `consumed_at`, `poll_count`, `last_polled_at`.
- `auth_sessions` — still unbuilt, and needed only when the SPA holds a
  credential of its own rather than a JWT: `session_id`, `user_id`,
  `token_hash`, `created_at`, `expires_at`, `revoked_at`, `last_seen_at`. The
  CLI does not need it. A JWT is verified against the account on every use, so
  disabling a user refuses their outstanding tokens immediately; what
  `auth_sessions` would add is revoking one browser without disabling the
  person.

Raw codes, raw approval tokens, and raw session tokens are never stored, never
logged, and never returned except in the single response or mail that mints
them.

### Login flow (`builtin`, email)

Login runs in a browser and is driven from the terminal: `kaiba auth login`
opens a browser, the person signs in there, and the token lands back in the
terminal. Retyping a code into a shell survives only as the fallback for hosts
that cannot open a browser.

This makes the CLI a **client of a running kaiba server** rather than a direct
opener of the store, which is the structural change in this revision. Today
`runAuthLoginRequest` calls `makeService(root:)` and mints the code against
local SQLite (`CommandAuth.swift:73`); it never speaks HTTP.

#### Handoff: pending login plus poll

The token returns to the terminal through a server-side pending-login row that
the CLI polls, not through a loopback redirect.

A loopback redirect — the CLI binds `127.0.0.1:<random>` and receives the token
as a redirect parameter, as `gcloud auth login` does — is simpler and needs no
polling, but it requires the browser and the CLI to be on the same machine.
That excludes the case this project actually has: `ssh` to the host holding the
note store and sign in with the browser already open on a laptop. It also
strands the email link, which lands on the server and has no route to a loopback
listener on some other host. Polling costs a little traffic against a server
that is already long-running and already serves a long-poll change feed.

1. `POST /note/login/start` with an optional `{email}` answers
   `{requestId, verificationURL, userCode, expiresIn, interval}` and writes a
   pending `auth_login_requests` row bound to no account yet.
2. The CLI prints `userCode` and opens `verificationURL`. With no browser
   available — headless, `ssh`, `--no-browser` — it prints the URL instead, to
   be opened anywhere, including on a phone.
3. The browser approves the pending row by one of the two methods below.
4. The CLI polls `POST /note/login/poll` with `{requestId}` every `interval`
   seconds, receiving `authorization_pending` until approval and a JWT once
   approved. The row is consumed on the first successful poll.

`userCode` is not a credential; it is the check that the browser and the
terminal are talking about the same request. The verification page displays it
and the person confirms it matches their terminal. Without it, a pending login
someone else started looks exactly like your own, and approving it hands them a
token for your account.

#### Approval in the browser

Both methods approve the same row, so the terminal does not care which was used.

**Email link.** The person enters their address on the verification page, or it
came in on `/note/login/start`; the server mails a link carrying a single-use
token bound to that pending request. Opening the link renders a confirmation
page showing `userCode` and the requesting client, and a button POSTs the
approval.

The link must not approve on a bare `GET`. Mail scanners and corporate link
rewriters fetch every URL in a message, so a `GET` that approves is consumed
before the person ever clicks it. Render on `GET`, approve on `POST`; the cost
is one click.

**Six-digit code.** The shipped `auth_login_codes` path, unchanged, entered on
the verification page or — with `--no-browser` — in the terminal. This is the
fallback for a host with no mail sender configured, where `LogMailSender`
writes the code to the server's stderr and a machine-local install can still
complete a login with no mail account at all.

Delivery is unchanged: `LogMailSender` by default, or
`ResendGatewayCLIMailSender` spawning `resend-gateway-writer emails send`.
Spawning the gateway rather than calling Resend's HTTPS API directly follows the
`agent-gateway` and AnydocKit adapters: kaiba keeps zero SwiftPM dependencies,
and — more usefully — the API key stays inside the gateway's own resolution
chain (explicit key, `RESEND_API_KEY`, then kinko), so it never passes through
kaiba's configuration, memory, or logs. Note that kinko resolution is
path-scoped: the gateway inherits the spawning process's working directory, so a
host that relies on kinko rather than the environment must run from a directory
where the key is registered.

Both methods stay fail closed. An address with no enabled `users` row mints
nothing and answers identically to one that does
(`NoteService+EmailLogin.swift:66`), and `/note/login/start` answers the same
whether or not the address exists, so neither endpoint is an enumeration
oracle.

#### CLI surface

```text
kaiba auth login [--endpoint <url>] [--email <address>] [--no-browser]
                 [--output json|text]
```

`--endpoint` follows the convention `kaiba graphql` already uses
(`Command.swift:222`); without it the CLI falls back to `server.endpoint` in
`config.json`, then `http://127.0.0.1:8787`. Against a server in `mode: none`
the command reports that the server needs no credential and exits without
opening anything.

Note the dispatch change: `runAuthLogin` currently rejects a bare
`kaiba auth login` with `auth login requires: request|verify`
(`CommandAuth.swift:29`). Under this design the bare form is the browser flow,
and `request` / `verify` stay as named actions beneath it.

`kaiba auth login request|verify` remain, unchanged, as the scriptable form and
as the only form that works with no server running: they open the store
directly and always will. `kaiba client issue` likewise remains the
non-interactive credential for scripts, which must never need a browser.

`POST /note/logout` revokes a browser session once `auth_sessions` exists; a
JWT is refused by disabling the account or by expiry until then.

### Login flow (`builtin`, external IdP)

The same account table, a different way of proving the address. The SPA runs
Authorization Code + PKCE against the configured issuer as a public client with
no client secret; the callback lands on an SPA route. kaiba verifies the
resulting ID token against the issuer's JWKS, extracts the verified email, and
issues **its own** session for the matching `auth_users` row. An address with
no enabled row is refused, exactly as with email login.

This is what makes the IdP optional rather than load-bearing: sessions,
revocation, and the account list stay kaiba's, so removing the IdP does not
strand anyone.

### Switching to a hosted provider

`mode: oidc` skips kaiba's session layer entirely and validates the issuer's
access token on every request (signature, issuer, audience, expiry, cached
JWKS). That is the Auth0 end state. The switch is a config change; the SPA
learns about it from the discovery endpoint below.

### Configuration

CLI flags cannot express an issuer URL, an audience, a JWKS endpoint, and SMTP
settings, so mode selection lives in `config.json` under a new `server.auth`
object, decoded by `KaibaConfiguration`
(`Sources/AppCore/KaibaConfiguration.swift:3`).

```json
{
  "server": {
    "endpoint": "http://127.0.0.1:8787",
    "auth": {
      "mode": "builtin",
      "builtin": {
        "sessionTTLHours": 720,
        "loginCodeTTLMinutes": 10,
        "mail": {
          "sender": "resend",
          "fromAddress": "kaiba@example.com",
          "apiKeyEnv": "KAIBA_RESEND_API_KEY"
        },
        "idp": {
          "issuer": "https://<tenant>.auth0.com/",
          "clientId": "<spa client id>"
        }
      },
      "oidc": {
        "issuer": "https://<tenant>.auth0.com/",
        "audience": "kaiba-note-api",
        "clientId": "<spa client id>",
        "jwksURL": "https://<tenant>.auth0.com/.well-known/jwks.json"
      }
    }
  }
}
```

Rules:

- The CLI flag wins over config. `--allow-unauthenticated` forces `none`
  regardless of the file, so a config file can never silently change the
  effective mode away from what the operator typed.
- `server.endpoint` is new and is read only by client-side commands — today
  `kaiba auth login`. It is where `--endpoint` falls back to, and it never
  affects what `kaiba serve` binds. The only `endpoint` in
  `KaibaConfiguration` now belongs to a storage profile
  (`KaibaConfiguration.swift:209`), so this is an addition, not a reuse.
- Secrets are named through environment variables only, following the existing
  `--access-key-env` convention. No secret values in `config.json`.
- Startup keeps printing the effective mode; the existing
  `auth=disabled (--allow-unauthenticated)` line generalizes to `auth=<mode>`.

### Discovery endpoint

With more than one mode the SPA can no longer infer what to do from a bare 401:
a paste-a-key screen is wrong for `builtin`, and an email form is wrong for
`oidc`.

`GET /note/auth-info` answers without authentication and returns only
non-secret facts:

```json
{ "mode": "builtin", "methods": ["email", "idp"], "idp": { "issuer": "...", "clientId": "..." } }
```

For `mode: "none"` it returns `{"mode":"none"}` and the SPA never shows a login
surface, which is the invariant the operator expects from
`--allow-unauthenticated`.

### SPA states

`appStore` gains an explicit `auth` state with three values: `unknown`,
`authenticated`, `unauthenticated`. A 401 from any transport call sets
`unauthenticated` and discards the stored token, rather than writing to
`error`.

`ChatbookView` selects the whole view on that state. When `unauthenticated`,
the reader grid, panes, and tree are not mounted at all; a login view renders
instead. The generic error banner keeps its current role for transport and
GraphQL failures only.

Login view by mode:

- `apiKey` — a field to paste a key from `kaiba client issue --name <n>`, plus
  instructions for the QR/registration flow. No server change is required: the
  pasted key is validated by the existing `authenticateAPIClient`.
- `builtin` — an email field, then a code field, plus an IdP button when one is
  configured. The same views serve the verification page reached from
  `kaiba auth login`, which arrives with `?request=<requestId>` and shows
  `userCode` so the person can match it against their terminal.
- `oidc` — a button starting Authorization Code + PKCE against the issuer.

### Token storage

`sessionStorage` moves to `localStorage` so a session survives a new tab and a
browser restart, keyed as today (`kaiba-note-bearer`). A 401 clears the key, so
a revoked or expired credential cannot wedge the app in a loop.

### Safety rules

- `mode: none` is refused unless the bind host is loopback. Serving the note
  store unauthenticated on a routable address must be impossible by accident.
  This is a hard failure, not a warning: the friendly path for LAN use is to
  run an authenticated mode.
- Login endpoints answer identically for known and unknown addresses.
- Login code requests and verification attempts are rate limited, and codes
  carry an attempt cap.
- The email approval link renders on `GET` and approves on `POST`, so a link
  prefetch by a mail scanner cannot consume it.
- `userCode` is shown in both the terminal and the browser, so a person cannot
  be walked into approving a login request they did not start.
- Pending logins expire in ten minutes, are single use, and are rate limited per
  source. Polling faster than `interval` answers `slow_down` rather than
  serving the request.
- `POST /note/login/poll` answers identically for an unknown, an expired, and an
  already-consumed `requestId`, so the endpoint reveals nothing about requests
  that are not the caller's.
- 401 bodies keep their current shape (`error` plus a GraphQL `errors` array)
  so existing clients are unaffected.
- Provider errors are logged server-side only, never returned in a response
  body, per `logNoteAPIServerError`
  (`QRClientRegistrationAuthenticator.swift:236`).

## Non-Goals

- Roles and per-note authorization. Every authenticated principal keeps full
  access to the note store; the schema has no per-user ACL.
- Self-service signup, password login, and account recovery flows.
- Multi-tenant hosting.

## Verification

- `swift build`, `swift test` for the provider seam, config decoding, the
  loopback guard, `/note/auth-info`, the login code lifecycle (single use,
  expiry, attempt cap), and session revocation.
- `swift test` for the pending-login lifecycle — pending, approved, consumed,
  expired — the `slow_down` guard, the refusal to approve on `GET`, and the
  uniform poll answer for unknown, expired, and consumed requests.
- `bun run test` in `web/` for the auth state machine, the 401 token discard,
  the login views, and the verification page's `userCode` display.
- Manual: `kaiba serve` in each mode, checking that `none` never shows a login
  surface and that a closed tab recovers without restarting the server.
- Manual: `kaiba auth login` twice against one server — once on the serving host
  with a local browser, once over `ssh` with `--no-browser` and the browser on a
  laptop — confirming both end with a usable `--jwt` token.
