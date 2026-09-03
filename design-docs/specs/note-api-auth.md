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
- Opening the URL serves the SPA only under `--web-root`: `GET /note/register`
  is routed to `routeNoteRegistrationChallenge`, which answers 403
  (`ServerContracts.swift:150-151`), and the index.html rewrite that lets the
  SPA load is a special case in `KaibaStaticAssetResolver.swift:104-110`. The
  SPA reads `?code=`, POSTs `{code, displayName}` to `/note/register`, receives
  a bearer token `rn_...`, and stores it (`web/src/notes/client.ts:55-72`).

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

1. ~~**No unauthenticated state in the SPA.**~~ Fixed since the first draft:
   `appStore` now carries an explicit `AuthState`
   (`web/src/state/appStore.tsx:56`, set on any 401), and `ChatbookView`
   renders `<LoginView>` instead of the reader shell when unauthenticated
   (`web/src/views/ChatbookView.tsx:145`), so "not logged in" is no longer
   indistinguishable from "empty store". See "What has shipped since".
2. ~~**The token is per-tab.**~~ Fixed since the first draft: the credential
   now lives in `localStorage` keyed `kaiba-note-bearer`
   (`web/src/notes/client.ts:720-728`), so it survives new tabs and browser
   restarts, and a 401 clears the key.
3. ~~**No account model.**~~ Fixed by the multi-user foundation: the existing
   `users` table is the account model, carries normalized email and disablement
   state, and owns notebooks and API clients. Browser-driven login and
   per-device browser-session revocation remain unimplemented; they must reuse
   `users`, not add a parallel `auth_users` table.
4. ~~**`--allow-unauthenticated` is unguarded.**~~ Fixed: `ServeCommand.parse`
   refuses `--allow-unauthenticated` unless the bind host is loopback
   (`127.0.0.0/8`, `::1`, or `localhost`), so serving the store unauthenticated
   on a routable address is a hard startup failure.
5. ~~**Served event activity exposes a shared revision.**~~ Fixed: `/note/events`
   returns an opaque, principal-bound cursor. Only events authorized for that
   principal advance or wake its poll, so foreign writes disclose neither
   mutation counts nor timing. A response returns a successor cursor; the
   request cursor retains its batch until that successor is used, making a
   dropped response and overlapping same-cursor requests replay-safe. Every
   replay rechecks current event visibility; revoked events are omitted and
   operational authorization errors preserve the batch for HTTP 500 retry.
6. **Login is a terminal transcription exercise.** The only working method is
   reading a six-digit code out of a mail client and retyping it into a shell.
   There is no browser path, so the SPA cannot log anyone in, and the CLI cannot
   log in to a server it does not share a filesystem with.
7. ~~**`GET /note/events` and `/note/agent-stream` are not scoped to the
   caller.**~~ Fixed: the route handler retains the authenticated principal,
   filters event metadata through a scoped service, and authorizes each stream
   turn before attaching it to the reply hub. The ownership reader is required
   for both routes, so an unwired handler fails closed.
8. **No cross-site, `Host`, or `Content-Type` guard on state-changing routes
   (open).** The GraphQL body is decoded as JSON without checking
   `Content-Type`, and no route reads `Origin` or `Host`. Under
   `--allow-unauthenticated` a cross-site `text/plain` form post can drive
   mutations against a local store, and an unchecked `Host` leaves DNS
   rebinding open. The exact accepted-host and origin rules are defined under
   Configuration and apply before authentication or body decoding.

## Design

### Target shape

kaiba runs its **own authentication server** inside `kaiba serve`. It owns the
account records and the sessions. Login methods plug into it, and one of those
methods may be an external IdP. Later, the entire authenticator can be swapped
for a hosted provider without touching routing or the note store.

| Mode | Provider | Selection |
| --- | --- | --- |
| `none` | no authenticator | `--allow-unauthenticated`, loopback only |
| `none` (as-admin) | no authenticator, requests act as the seeded admin | `--allow-unauthenticated --as-admin`, loopback only |
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

**Fail closed on accounts.** An address can log in only if an enabled `users`
row exists for it. There is no self-signup and no first-visitor claim. Accounts
are created out of band with `kaiba user add --email`.

### Storage

Accounts are the existing `users` table (`NoteStoreSchema.swift:449`). It
already has `email` with a unique partial index, `display_name`, `created_at`,
`disabled_at`, and `is_admin`, and notebook ownership already references it.

- `auth_login_codes` — shipped (`NoteStoreSchema.swift:470`): `code_id`,
  `user_id`, `code_hash`, `attempts`, `created_at`, `expires_at`,
  `consumed_at`. Single use, capped at five attempts, at most three live per
  account.
- `auth_login_requests` — new, and the whole of the browser handoff:
  `request_id`, `user_code`, `poll_secret_hash`, `approval_token_hash`,
  `user_id` (null until approved), `client_description`, `created_at`,
  `expires_at`, `approved_at`, `consumed_at`, `poll_count`, `last_polled_at`.
  `request_id` is the public name of the row — it may appear in the
  verification URL and on screen. `poll_secret` is the credential the polling
  client uses; it is returned once by `/note/login/start`, stored server-side
  only as a hash, and never appears in any URL (see "Handoff" below).
- `auth_sessions` — still unbuilt, and needed only when the SPA holds a
  credential of its own rather than a JWT: `session_id`, `user_id`,
  `token_hash`, `created_at`, `expires_at`, `revoked_at`, `last_seen_at`. The
  CLI does not need it. A JWT is verified against the account on every use, so
  disabling a user refuses their outstanding tokens immediately; what
  `auth_sessions` would add is revoking one browser without disabling the
  person.

Neither table exists yet. When a later release adds `auth_login_requests` it
increments `NoteStoreSchema.currentVersion` and requires store recreation
(P9); Kaiba carries no migrations. `auth_sessions` is further deferred on the
P6 expiry decision.

Raw codes, approval tokens, poll secrets, and session tokens are never
persisted server-side or logged, and are returned only through the single
response or mail that mints them. The CLI keeps `pollSecret` in memory. A
standalone SPA keeps it only in same-origin `sessionStorage` until its pending
login reaches a terminal state; it never enters a URL or `localStorage`.

The JWT signing key (`auth.jwt.secret`) shares the `app_settings` table but is
**not reachable through the `appSetting`/`setAppSetting` GraphQL surface**: keys
under the reserved `auth.` prefix are refused there (only internal token code
reaches them), so a bearer-token holder can neither read the key to forge an
admin JWT nor overwrite it. This closed a privilege-escalation hole where any
authenticated client could sign a token for any account. First-use creation is
one transaction with `INSERT ... ON CONFLICT DO NOTHING` followed by a reread,
so concurrent issuers always sign with the canonical stored key.

### Login flow (`builtin`, email)

Login runs in a browser and is initiated either by `kaiba auth login` or by the
standalone SPA. In the CLI flow the command opens a browser and the token lands
back in the terminal; in the standalone flow the initiating tab polls for and
stores the token. Retyping a code into a shell survives only as the fallback
for hosts that cannot open a browser.

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
   `{requestId, pollSecret, verificationURL, userCode, expiresIn, interval}`
   and writes a pending `auth_login_requests` row bound to no account yet.
2. The CLI prints `userCode` and opens `verificationURL`. With no browser
   available — headless, `ssh`, `--no-browser` — it prints the URL instead, to
   be opened anywhere, including on a phone.
3. The browser approves the pending row by one of the two methods below.
4. The CLI polls `POST /note/login/poll` with `{requestId, pollSecret}` every
   `interval` seconds, receiving `authorization_pending` until approval and a
   JWT once approved. The row is consumed on the first successful poll.

`pollSecret` exists because the poll is what a JWT is handed to, and
`requestId` cannot be that credential: the verification URL carries
`?request=<requestId>`, so the id lands in browser history, on a phone screen,
and in anything that logs URLs. This is RFC 8628's split between the
`device_code` (secret, held only by the polling client) and the `user_code`
(public, shown to the person); kaiba keeps `requestId` public and moves the
polling right into a separate secret held only by the polling client and as a
hash in the row.

`userCode` is not a credential; it is the check that the browser and the
terminal are talking about the same request. The verification page displays it
and the person confirms it matches their terminal. Without it, a pending login
someone else started looks exactly like your own, and approving it hands them a
token for your account.

#### Standalone SPA handoff

The SPA uses the same pending-login protocol; it does not get a second token
exchange. When no `request` query parameter is present, the `builtin` login
view calls `POST /note/login/start` itself, keeps `{requestId, pollSecret}` in
same-origin `sessionStorage`, and then drives email-link or six-digit-code
approval against that request. The polling tab calls `/note/login/poll`; only
that one-time poll returns the JWT. The approval GET/POST and code endpoint
never return a credential.

`sessionStorage` is deliberate: it survives a same-tab mail-link navigation or
reload but is not durable across browser restarts and is not shared as the
long-lived API bearer is. The SPA deletes the pending pair on successful poll,
expiry, cancellation, or authentication failure, then stores only the returned
JWT under the existing `kaiba-note-bearer` `localStorage` key. A link opened in
another tab approves the row but tells the person to return to the polling tab;
knowing `requestId` alone can never retrieve its JWT.

#### Approval in the browser

Both methods approve the same row, so the polling client does not care which
was used.

**Email link.** The person enters their address on the verification page, or it
came in on `/note/login/start`; the server mails a link carrying a single-use
token bound to that pending request. Opening the link renders a confirmation
page showing `userCode` and the requesting client, and a button POSTs the
approval.

The link must not approve on a bare `GET`. Mail scanners and corporate link
rewriters fetch every URL in a message, so a `GET` that approves is consumed
before the person ever clicks it. Render on `GET`, approve on `POST`; the cost
is one click.

**Six-digit code.** The shipped `auth_login_codes` path, extended to approve a
pending row: entered on the verification page or — with `--no-browser` — in the
terminal. `verifyEmailLoginCode` today mints a JWT directly and knows nothing
about `auth_login_requests`; the browser flow needs it to take an optional
`requestId` and, when present, mark that pending row approved instead of
returning a token to the verifier. This is the fallback for a host with no mail
sender configured, where `LogMailSender` writes the code to the server's stderr
and a machine-local install can still complete a login with no mail account at
all.

**Approval endpoints.** The routes the two methods above need, none of which
exist yet (`ServerContracts.swift` routes only `/graphql`, `/note/register`,
`/note/events`, `/note/agent-stream`, and the SPA fallbacks):

- `POST /note/login/email` — from the verification page, request the mailed
  approval link/code for a pending `requestId`.
- `GET /note/login/approve` renders the confirmation page (showing `userCode`
  and the requesting client); `POST /note/login/approve` approves the row.
  Split so a mail scanner's `GET` prefetch cannot consume the link.
- `POST /note/login/code` — submit a six-digit code against a pending
  `requestId`.

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
issues **its own** session for the matching `users` row. An address with
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
    "allowedHosts": ["notes.example.com"],
    "allowedOrigins": ["https://notes.example.com"],
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
- `server.allowedHosts` contains exact HTTP authority values accepted in the
  `Host` header; `server.allowedOrigins` contains exact origins allowed on
  state-changing browser requests. Neither accepts wildcards, suffix matches,
  paths, queries, fragments, credentials, or forwarded-host headers.
- Host normalization lowercases DNS names, removes one trailing dot, preserves
  an explicit port, and uses bracketed canonical IPv6. Missing, malformed, or
  unmatched `Host` answers 400 before authentication or body decoding. The
  default allowlist is the actual bind authority; when that bind is loopback,
  the same listener port on `localhost`, `127.0.0.1`, and `[::1]` is also
  accepted. Reverse-proxy and non-loopback names must be listed explicitly.
- A state-changing request with `Origin` must exactly match the normalized
  request origin or an entry in `server.allowedOrigins`; `Origin: null` and an
  unmatched origin answer 403. An absent `Origin` remains valid for CLI and
  other non-browser clients, including a loopback `mode: none` client, after
  Host and required JSON content-type validation. Allowed cross-origin
  responses echo the one matched origin with `Vary: Origin`; `*` is never used
  with credentials.
- The normalized request origin is `http://` plus the validated Host authority,
  because `KaibaLocalHTTPServer` itself serves HTTP. An HTTPS reverse proxy
  lists its public origin explicitly in `allowedOrigins`; forwarded proto and
  forwarded host headers are never trusted implicitly.
- `server.endpoint` does not grant Host or Origin access. It is a client-side
  default and may differ from the public reverse-proxy origin.
- Secrets are named through environment variables only, following the existing
  `--access-key-env` convention. No secret values in `config.json`.
- Startup keeps printing the effective mode; the existing
  `auth=disabled (--allow-unauthenticated)` line generalizes to `auth=<mode>`.
- `sessionTTLHours` sets the JWT `exp` until `auth_sessions` exists (it is the
  only credential today). The 720h/30-day default is long for a token handed to
  agents via `kaiba --jwt` and, with revocation-by-expiry as the only lever
  until sessions ship (see "CLI surface"), should be shortened before `builtin`
  mode lands.
- The pending-login TTL is fixed at ten minutes (Safety rules) and is not yet a
  config key; add `pendingLoginTTLMinutes` to `builtin` when it needs tuning.

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
  configured. A standalone login starts and polls its own pending request as
  described above. The same views serve the verification page reached from
  `kaiba auth login`, which arrives with `?request=<requestId>` and shows
  `userCode` so the person can match it against their terminal.
- `oidc` — a button starting Authorization Code + PKCE against the issuer.

### Token storage

Shipped: the credential lives in `localStorage` keyed `kaiba-note-bearer`
(`web/src/notes/client.ts:720-728`), so a session survives a new tab and a
browser restart. A 401 clears the key, so a revoked or expired credential
cannot wedge the app in a loop.

The future standalone `builtin` flow stores only its short-lived pending pair
in `sessionStorage`; successful polling deletes that pair before writing the
JWT to `kaiba-note-bearer`. Approval pages never receive or persist the JWT.

### Safety rules

- `mode: none` is refused unless the bind host is loopback. Serving the note
  store unauthenticated on a routable address must be impossible by accident.
  This is a hard failure, not a warning: the friendly path for LAN use is to
  run an authenticated mode. Implemented for the current `--allow-unauthenticated`
  flag in `ServeCommand.parse`.
- Every state-changing JSON route, including GraphQL, login, registration, and
  agent-token issuance, requires `Content-Type: application/json`; unsupported
  media types answer 415 before decoding. The exact Host and Origin checks in
  Configuration run before authentication and prevent DNS-rebinding and
  browser cross-site mutation even when the local server uses `mode: none`.
- Stored attachments served at `GET /files/<id>` are inert downloads: an
  author-supplied media type is honored only for a small allowlist of
  render-safe types, everything else (notably `text/html` and
  `image/svg+xml`) is forced to `application/octet-stream`, and every response
  carries `Content-Disposition: attachment` (or `inline` for the allowlist),
  `Content-Security-Policy: default-src 'none'; sandbox`, and `nosniff` — so a
  malicious attachment cannot run script on kaiba's origin and steal the SPA's
  bearer token.
- `GET /files/<id>` scopes its reader to the authenticated account, so
  per-account library membership is enforced on raw bytes exactly as the
  GraphQL executor enforces it. Ownership enforcement and the default-user
  fallback for an unauthenticated host are designed in
  `design-docs/specs/multi-user.md`.
- Store-wide file maintenance (`migrateAllNoteFiles`, `reclaimNoteFileStorage`)
  is refused to non-admin clients: only the unscoped local operator or an acting
  admin may sweep or migrate blobs across every library.
- Login endpoints answer identically for known and unknown addresses.
- Login code verification attempts carry an attempt cap (`auth_login_codes.attempts`,
  capped at five across all live codes), and an account may hold at most three
  live codes at once. **Open item:** there is no per-source (IP) rate limit on
  `/note/login/start` yet — no column, bucket table, or counter keyed by source
  exists — so once that unauthenticated, mail-triggering route ships it must
  gain one, or an attacker who knows one enrolled address can mail-bomb it. The
  identical-answer property does not mitigate this.
- The email approval link renders on `GET` and approves on `POST`, so a link
  prefetch by a mail scanner cannot consume it.
- `userCode` is shown in both the terminal and the browser, so a person cannot
  be walked into approving a login request they did not start.
- Pending logins expire in ten minutes, are single use, and are rate limited per
  source. Polling faster than `interval` answers `slow_down` rather than
  serving the request.
- `POST /note/login/poll` answers identically for an unknown, an expired, an
  already-consumed `requestId`, and a wrong `pollSecret`, so the endpoint
  reveals nothing about requests that are not the caller's. A token is
  released only to the holder of `pollSecret`, never to a caller who merely
  knows `requestId`.
- 401 bodies keep their current shape (`error` plus a GraphQL `errors` array)
  so existing clients are unaffected.
- `POST /note/agent-token` mints only for
  the authenticated `NoteAPIAuthenticatedClient.userId`, accepts no account id
  from the caller, bounds TTL, re-reads account state, and refuses requests on
  every unauthenticated host, including `--allow-unauthenticated`. The token is
  returned once and never logged.
- Provider errors are logged server-side only, never returned in a response
  body, per `logNoteAPIServerError`
  (`QRClientRegistrationAuthenticator.swift:236`).

## Non-Goals

- Notebook sharing, roles beyond the existing admin role, and per-note ACLs.
  The multi-user boundary is one owner per notebook; admin widens library
  reach but does not grant access to another account's notebooks.
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
