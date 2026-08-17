# Note API Authentication

**Status**: Draft
**Supersedes in part**: `kaiba-note.md` ("HTTP Note API and Web Viewer")

## Purpose

Give kaiba its own authentication server with email-based login, keep external
identity providers usable as a login method, and allow the whole thing to be
switched to a hosted provider such as Auth0 later. Along the way, give the web
viewer a real unauthenticated state instead of rendering the reader shell
behind a generic error banner.

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

**Sessions are opaque and database-backed, not JWT.** kaiba already owns a
local SQLite store, so a random token hashed with SHA-256 (mirroring
`api_clients`) is strictly better than a signed claim: it is revocable
immediately, it needs no key management, and it needs no new dependency.
JWT verification appears only in `oidc` mode, where kaiba is the verifier and
the issuer holds the keys.

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

Three tables, in the same migration style as `api_clients`:

- `auth_users` — `user_id`, `email` (unique, normalized), `display_name`,
  `created_at`, `disabled_at`.
- `auth_login_codes` — `code_hash`, `user_id`, `expires_at`, `consumed_at`,
  `attempts`, `requested_from`. Codes are single-use with a small attempt cap.
- `auth_sessions` — `session_id`, `user_id`, `token_hash`, `created_at`,
  `expires_at`, `revoked_at`, `last_seen_at`.

Raw codes and raw session tokens are never stored, never logged, and never
returned except in the response that mints them.

### Login flow (`builtin`, email)

1. `POST /note/login/email` with `{email}`. The server answers 202 with no
   detail regardless of whether the address exists, so the endpoint cannot be
   used to enumerate accounts. Rate limited per address and per source.
2. The code is delivered by the configured mail sender. Two exist:
   `LogMailSender`, the default, writes the message to stderr so a
   machine-local install can complete a login with no mail account; and
   `ResendGatewayCLIMailSender` spawns `resend-gateway-writer emails send`.

   Spawning the gateway rather than calling Resend's HTTPS API directly follows
   the `agent-gateway` and AnydocKit adapters: kaiba keeps zero SwiftPM
   dependencies, and — more usefully — the API key stays inside the gateway's
   own resolution chain (explicit key, `RESEND_API_KEY`, then kinko), so it
   never passes through kaiba's configuration, memory, or logs.

   Note that kinko resolution is path-scoped: the gateway inherits the spawning
   process's working directory, so a host that relies on kinko rather than the
   environment must run from a directory where the key is registered.
3. `POST /note/login/verify` with `{email, code}` mints a session token
   (`ks_...`), stores its hash, and returns it once. Wrong or expired codes
   answer 401 and burn an attempt.
4. `POST /note/logout` revokes the session.

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
  configured.
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
- `bun run test` in `web/` for the auth state machine, the 401 token discard,
  and the login views.
- Manual: `kaiba serve` in each mode, checking that `none` never shows a login
  surface and that a closed tab recovers without restarting the server.
