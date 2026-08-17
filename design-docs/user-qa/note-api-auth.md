# Note API Authentication — Decisions

Design reference: `design-docs/specs/note-api-auth.md`

## Answered

### Should auth on/off be two binaries or one binary with an option?

One binary with a runtime-selected provider. Two binaries duplicate the
Homebrew formula and Cask, double signing and notarization, and make an
unauthenticated build a shipped artifact.

### Should the web viewer render the reader shell when the API returns 401?

No. It must render a login view instead. The current behavior shows the full
reader with `No notebooks yet.`, which is indistinguishable from an empty
store, and its `Retry` button cannot recover.

### Can Vapor's built-in authentication be used?

Not without adopting Vapor. kaiba has one external package (`anydoc-swift`) and
a hand-written Network.framework server; Vapor would replace that layer and add
SwiftNIO to a Homebrew-distributed CLI. Nothing in this design needs it.

### Does the OpenStack Keystone model apply?

The quoted text describes OpenStack Swift, the object store, not this project.
The pattern it names — an external issuer mints the token, this service only
validates it — is the `oidc` mode in the design, so the requirement is kept.

### P1: Which providers, in what order?

Target: kaiba's own auth server first, with email login and optional external
IdP federation; switching wholesale to a hosted provider comes after.

Order: SPA login state -> mode plumbing and guards -> configuration ->
`builtin` with email login -> IdP federation inside `builtin` -> `oidc` as a
full switch. `apiKey` is kept permanently for CLI and script access, which must
never require a browser.

### P2: What KDF for password storage?

None: the built-in method is passwordless. A single-use, short-lived, rate
limited email code replaces the password, so there is nothing to derive a key
from. This sidesteps the portability problem (CryptoKit and swift-crypto lack
PBKDF2/Argon2, CommonCrypto is Apple-only, kaiba builds for Linux) rather than
answering it, and drops password reset and breach exposure along with it.
Passwords can be added later behind the same seam.

### P3: OIDC redirect and client secret?

Public SPA client, Authorization Code + PKCE, no client secret. The callback
lands on an SPA route. A confidential client would force kaiba to hold a secret
and own the callback, which is not worth it for a locally hosted note server.

### P4: Non-loopback plus `--allow-unauthenticated` — error or warning?

Hard error. A warning leaves the exposure possible, and the friendly path for
LAN use is to run an authenticated mode.

### Are sessions JWT?

Revised: yes for the process-to-process credential. The CLI is a separate
process that opens the store directly, and an agent must be able to run
`kaiba --jwt <token>` as the user who asked it to, so that credential is an
HS256 JWT signed with a key generated on first use and stored in the store's
`app_settings`.

Revocation still does not depend on expiry: verification re-reads the account,
so disabling a user refuses their outstanding tokens immediately. Browser
sessions may still be opaque rows; the two are not in conflict.

### How does an agent write as the user who asked?

The browser calls the server with its session credential; the server mints a
short-lived token for that user and hands it to the agent with the task; the
agent runs `kaiba --jwt <token> ...`. The note is then owned by and attributed
to that user, and the agent never sees a password, a session cookie, or the
signing key.

### Can anyone with an email address log in?

No. Fail closed: an enabled `auth_users` row must already exist for the
address. Accounts are created out of band with `kaiba auth user add --email`.
No self-signup, no first-visitor claim.

### P5: Mail delivery

Resend, through `tacogips/resend-gateway` — implemented, no longer deferred.
`ResendGatewayCLIMailSender` spawns `resend-gateway-writer emails send`, so the
API key stays in the gateway's own resolution chain (explicit key,
`RESEND_API_KEY`, then kinko) and never reaches kaiba's configuration or logs.
No Swift SDK dependency, matching how kaiba already talks to `agent-gateway`.

Verified against the live account: a code was mailed from `onboarding@resend.dev`
and Resend reported `last_event: delivered`. That account has no verified
domain, so it is in test mode and can only send to its own address; sending
anywhere else fails with a 403 naming the permitted address. Real use needs a
verified domain at resend.com/domains and a `from` on it.

## Pending

### P6: Session TTL and idle expiry

The design carries a fixed TTL (default 30 days) with no idle timeout and no
refresh. Whether a personal note server needs sliding expiry is unresolved.

**Impact**: TASK-402.
