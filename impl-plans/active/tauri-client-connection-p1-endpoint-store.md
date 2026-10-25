# P1: endpoint store helpers (recent servers, http warning, active label)

planId: `tauri-client-connection-p1-endpoint-store`. Wave 1, with no
dependencies.
Index and shared rules: `impl-plans/active/tauri-client-connection.md`
(the edit protocol, evidence policy and invariants all apply).
Design: `design-docs/specs/tauri-client-apps.md`, sections "Recent remote
endpoints" and "Connection settings" (plain-`http` warning, active connection
line).

## Intent and context

`web/src/notes/serverEndpoint.ts` (207 lines) owns every native endpoint and
credential rule. Add the pure storage and format helpers that the settings UI
(P3) needs. No UI work happens in this plan.

## writePaths

- `web/src/notes/serverEndpoint.ts`
- `web/src/notes/serverEndpoint.test.ts`
- `tmp/tauri-client-connection/P1`

## Exact additions (contract consumed by P3; names and signatures are fixed)

```ts
export const recentServerEndpointsStorageKey = 'kaiba-recent-server-endpoints'
export const recentServerEndpointLimit = 5
export function readRecentServerEndpoints(storage?: EndpointStorage): string[]
export function recordRecentServerEndpoint(endpoint: string, storage?: EndpointStorage): string[]
export function isUnencryptedRemoteEndpoint(value: string): boolean
export function activeConnectionLabel(storage?: EndpointStorage): string
```

Behavior:

- `readRecentServerEndpoints`: resolve storage the same way as
  `serverEndpoint.ts:readServerEndpoint`
  (`storage ?? availableEndpointStorage()`). Return `[]` in each of these
  cases: no storage, a missing key, JSON that fails to parse, or a value that
  is not an array. Otherwise keep only the string entries, map each through
  `normalizeServerEndpoint` and drop any that throw, remove duplicates
  keeping the first, and cap the result at `recentServerEndpointLimit`.
  The function never throws.
- `recordRecentServerEndpoint`: normalize the endpoint with
  `normalizeServerEndpoint` and let an invalid value throw. If no storage is
  available, throw `Error('Server settings are unavailable in this
  environment.')` (the same text as `saveServerEndpoint`). Build the new list:
  the normalized endpoint first, then the
  `readRecentServerEndpoints(storage)` result minus that endpoint, sliced to
  5. Write it with `setItem(key, JSON.stringify(list))` and return it. Never
  touch any credential key.
- `isUnencryptedRemoteEndpoint`: return `false` if
  `normalizeServerEndpoint(value)` throws. Return `true` only when the
  protocol is `http:` and the hostname is not loopback. Loopback here means
  `localhost`, any IPv4 address whose first octet is `127`, or `[::1]`.
- `activeConnectionLabel`: when `readConnectionMode(storage) === 'local'`,
  return `'Local — this Mac'`, using the same em dash as the existing
  `<option>` text in `ServerConnectionSettings.tsx`. Otherwise return
  ``` `Remote — ${new URL(readServerEndpoint(storage)).host}` ```, where
  `host` includes a non-default port.

## Patterns to imitate

- `serverEndpoint.ts:readServerEndpoint` for defensive reads that fall back
  instead of failing.
- `serverEndpoint.ts:saveServerEndpoint` for storage resolution and its
  "unavailable" error.
- `serverEndpoint.test.ts:memoryStorage` for the test storage. Reuse it, and
  call `setItem` for extra keys.

## Pitfalls

- WHATWG `URL.hostname` keeps the brackets on IPv6 (`'[::1]'`). Compare it
  against the bracketed form.
- `new URL('http://127.1')` normalizes the host to `127.0.0.1`. Test the
  normalized hostname, not the raw input.
- `readConnectionMode` with no mode key consults `navigator.userAgent`
  through `supportsLocalService`. In tests, always set
  `connectionModeStorageKey` explicitly so the result does not depend on the
  runner's UA.
- Do not change, reorder or re-export the existing functions, and do not
  touch `availableEndpointStorage`'s visibility. P2 deliberately does not
  import it.
- The recent list stores origins only. Never write a bearer into it or
  derive one from it.
- Keep the file under 1000 lines. It should grow by about 50 lines.

## Tests to add (in `web/src/notes/serverEndpoint.test.ts`, bun:test)

Each case is a situation followed by its expected outcome:

- Empty storage: `readRecentServerEndpoints` returns `[]`.
- Stored value `'not json'`, or `'{"a":1}'`: returns `[]` and does not throw.
- Stored `["https://a.example/", "ftp://x", 42, "https://a.example",
  "http://b.example:8787"]`: returns `["https://a.example",
  "http://b.example:8787"]`.
- Recording `'https://c.example/'` into a list of five: `c` comes first,
  length stays 5, the oldest entry is evicted, and the JSON is written
  under `kaiba-recent-server-endpoints`.
- Re-recording an existing entry moves it to the front without duplicating
  it.
- Recording `'https://x.example/path'` throws the validator message and
  leaves storage unchanged.
- Recording leaves every `kaiba-note-bearer:*` key byte-identical, including
  the key of an evicted origin.
- `isUnencryptedRemoteEndpoint`: `http://192.168.1.20:8787` gives true;
  `http://notes.example.com` gives true; `http://127.0.0.1:8787`,
  `http://127.1:8787`, `http://localhost:8787`, `http://[::1]:8787`,
  `https://192.168.1.20` and `'garbage'` give false.
- `activeConnectionLabel`: mode `local` gives `'Local — this Mac'`. Mode
  `remote` with endpoint `https://notes.example.com:8443` gives
  `'Remote — notes.example.com:8443'`. Mode `remote` with no endpoint gives
  `'Remote — 127.0.0.1:8787'`, the default endpoint.

## Verification (each tee'd into `tmp/tauri-client-connection/P1/`)

- `cd web && bun test src/notes/serverEndpoint.test.ts`: exit 0, with the
  pass count greater than the pre-change count (18 existing tests; expect at least 28). Record
  both counts.
- `bunx tsc --noEmit -p web`: exit 0. A failure that points only at peer
  files is recorded as peer drift, not as a P1 failure.
- `cd web && bunx eslint src/notes/serverEndpoint.ts
  src/notes/serverEndpoint.test.ts`: exit 0.

## Done criteria (mechanically checkable)

- `grep -c "export function readRecentServerEndpoints\|export function
  recordRecentServerEndpoint\|export function isUnencryptedRemoteEndpoint\|export
  function activeConnectionLabel" web/src/notes/serverEndpoint.ts` prints 4.
- `wc -l web/src/notes/serverEndpoint.ts` is under 1000.
- `tmp/tauri-client-connection/P1/progress.md` ends with `status: done`.
