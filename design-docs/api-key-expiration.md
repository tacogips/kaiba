# API key configuration and expiration

## Responsibility

API keys are administered on the server host using `kaiba client issue`,
`kaiba client list`, and `kaiba client revoke`. Here, “client” identifies the
credential's consumer. These commands operate on the server's local store and
require store administrator authority. The browser/native client accepts and
stores an issued key for the selected server origin and sends it as a bearer
credential. Expiration is enforced by the server's clock and database.

## Issuance contract

`kaiba client issue --name <name> [--user <user-id>] [--expires-at YYYY-MM-DD | --never]`

- The name identifies the consumer; `--user` selects the account it acts as.
  Omitting `--user` retains the existing default-account behavior.
- `--expires-at` accepts an exact ASCII Gregorian date, from year 0001 to 9999.
  The key remains valid for the entire selected day in UTC and expires at the
  following UTC midnight. Invalid dates are rejected before a key is stored.
- `--never` explicitly chooses no expiration. Omitting both options also means
  never, preserving existing CLI behavior and QR registration behavior.
- Supplying both expiration options is an error. A past expiration date yields
  a credential that is already expired.
- Expiration is fixed at issuance. Replace a key by issuing another and revoking
  the old one. The plaintext secret is printed once; storage retains its SHA-256
  hash, name, owner, creation date, expiration, last use, and revocation date.
- Issue/list output reports `expiresAt` as the selected date or JSON null;
  text output uses `never` for no expiration. List output never returns the key.

## Storage and enforcement

Schema v24 adds nullable `api_clients.expires_at TEXT`. NULL means never.
Fresh stores include the column; supported v19–v23 stores upgrade through v24.
Existing credentials retain their hashes and owner and receive NULL expiration.

The service validates dates even when called without the CLI. Authentication
requires a matching hash, an enabled owner, no revocation, and either NULL
expiration or a date at least as recent as the current UTC date. The date
comparison is safe because validation ensures canonical YYYY-MM-DD strings.
Authentication samples server time once and uses it for checking expiry and
recording `last_seen_at`. An expired request is rejected without updating that
field. Production entry points always use server time; the internal clock seam
supports deterministic boundary verification.

## Verification

Cover dated and never issuance, option conflicts, invalid dates, the last
millisecond of the selected UTC date and the following midnight, unchanged
last use on rejection, account disabling and revocation for permanent keys,
and migration that preserves existing credentials. Run focused Swift tests,
build, SwiftLint, and the whitespace check. Client UI code needs no expiration
editor for this feature.
