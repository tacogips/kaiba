# Tauri macOS and iPhone clients

**Status**: Completed
**Design Reference**: `design-docs/specs/tauri-client-apps.md`
(Transport boundary, Endpoint validation, Platform behavior, Native
permissions, Build surfaces, Rollout constraints);
`design-docs/user-qa/tauri-client-apps.md`;
`design-docs/specs/architecture.md` (Release Surfaces)

## Purpose

Ship the existing SolidJS note client as installable macOS and iPhone apps
without a second note domain, database, or API implementation, and land the
change set. The implementation work (deliverables 1-4) is present in the
working tree but entirely uncommitted; it has never been audited against the
accepted design, the validation gates have never been executed, the README
lacks the `Kaiba.app` naming caveat the design makes a close-out obligation,
and the plan still sits in `impl-plans/active/`. This revision covers that
residual close-out.

## Deliverables

- [x] Shared-client architecture and server boundary recorded
      (`design-docs/specs/tauri-client-apps.md`,
      `design-docs/user-qa/tauri-client-apps.md`,
      `design-docs/specs/architecture.md` Release Surfaces).
- [x] Tauri-aware HTTP transport and native endpoint controls
      (`web/src/notes/serverEndpoint.ts`, `serverEndpoint.test.ts`,
      `web/src/components/ServerConnectionSettings.tsx`, wired through
      `web/src/notes/client.ts`, `web/src/notes/events.ts`,
      `web/src/views/ConfigView.tsx`, `web/src/views/LoginView.tsx`).
- [x] Tauri 2 Rust shell and Apple configuration (`web/src-tauri/`:
      `Cargo.toml`, `Cargo.lock`, `build.rs`, `src/lib.rs`, `src/main.rs`,
      `tauri.conf.json`, `capabilities/default.json`, `icons/`).
- [x] Apple project generated and macOS/iPhone builds verified
      (`web/src-tauri/gen/apple/` XcodeGen inputs; local build evidence
      `gen/apple/build/arm64-sim/` and `kaiba-client_iOS.xcarchive`, ignored
      and therefore local-only — recorded in the user-qa doc).

The four boxes above record what the working tree contains. They are **not**
evidence that the tree matches the accepted design. TASK-000 re-verifies each
one against the repository, and its audit table — not these checkboxes — is
what satisfies workflow acceptance criterion 1.

- [x] Every design-stated behavior audited against file evidence in the
      working tree, each row confirmed or fixed (TASK-000).
- [x] `README.md` "macOS and iPhone clients" section carries the `Kaiba.app`
      naming caveat (TASK-001).
- [x] `design-docs/specs/macos-menu-bar-app.md` back-references the client
      spec at the name-collision point (TASK-002).
- [x] The three unasserted `resolveServerRequest` contracts are covered in
      `web/src/notes/serverEndpoint.test.ts`, and `mise run web:check`,
      `mise run tauri:check`, `mise run test` all pass unmodified (TASK-003).
- [x] Change set staged per the staging contract, plan relocated to
      `impl-plans/completed/tauri-client-apps.md`, committed and pushed
      (TASK-004, TASK-005).

## Tasks

### TASK-000: Deliverable audit against the repository

**Parallelizable**: Yes (read-only audit; write scope is only whatever fix a
failing row demands, plus this plan's progress log)

**Dependencies**: none. Must complete before TASK-003.

Workflow acceptance criterion 1 requires every deliverable to be verified
against the actual repository rather than assumed from a checkbox. The gates
in TASK-003 cannot do this: `web:check`, `tauri:check` and `mise run test`
prove that the tree typechecks, lints, builds and passes its suites, but no
gate asserts native-only rendering, safe-area padding, platform floors,
version parity, or capability scope. Those are design statements carried by
configuration and JSX, not by tests.

Walk each row below, open the cited file, and record `confirmed` or the fix
applied in the progress log. Every row derives from a named section of
`design-docs/specs/tauri-client-apps.md`; rows 17-18 cover Build surfaces, so
that `mise.toml` and `web/vite.config.ts` — both in the commit — are not
audited only by the gates that happen to invoke them.

| # | Design section | Claim to verify | File evidence |
|---|---|---|---|
| 1 | Transport boundary | Runtime detection is the only switch; browser keeps same-origin `fetch`, Tauri routes through the HTTP plugin | `web/src/notes/serverEndpoint.ts` (`isTauriRuntime`, `serverRequest`) |
| 2 | Transport boundary | Relative note API paths resolve against the stored endpoint; query strings on a request path survive | `web/src/notes/serverEndpoint.ts` (`resolveServerRequest`) |
| 3 | Transport boundary | Absolute URL kept as its own target; non-string `RequestInfo`/`URL` passed through untouched | `web/src/notes/serverEndpoint.ts` (`resolveServerRequest`) |
| 4 | Transport boundary | `/note/events` long-poll routes through the same transport | `web/src/notes/events.ts` (imports `serverRequest`, uses it as the default `fetchImpl`) |
| 5 | Transport boundary | Registration reports `Kaiba App` natively, `Kaiba Web` from a browser | `web/src/notes/client.ts` (`displayName` on the register call); the runtime-unaware login hint at `web/src/views/LoginView.tsx:75` is the accepted divergence |
| 6 | Endpoint validation | Scheme restricted to `http`/`https`; user info, query, fragment and any path beyond `/` rejected; normalized to origin without trailing slash | `web/src/notes/serverEndpoint.ts` (`normalizeServerEndpoint`) |
| 7 | Endpoint validation | Absent stored value yields the default; an invalid stored value falls back to the default rather than failing the client | `web/src/notes/serverEndpoint.ts` (`readServerEndpoint`) |
| 8 | Platform behavior | Default endpoint is `http://127.0.0.1:8787` | `web/src/notes/serverEndpoint.ts` (`defaultServerEndpoint`) |
| 9 | Platform behavior | Endpoint control renders **only** in a native runtime, in two places: Config screen and a compact form on the login screen; saving reloads the WebView | `web/src/components/ServerConnectionSettings.tsx` (`<Show when={isTauriRuntime()}>`, `compact` prop, reload on save), `web/src/views/ConfigView.tsx`, `web/src/views/LoginView.tsx` |
| 10 | Platform behavior | `viewport-fit=cover` plus `env(safe-area-inset-*)` padding on the body, with no phone-specific layout branch | `web/index.html` (viewport meta), `web/src/styles.css` (`body` padding) |
| 11 | Native permissions | Capability permits `http://**` and `https://**` for the `main` window because the host is user-configurable | `web/src-tauri/capabilities/default.json` |
| 12 | Native permissions | HTTP plugin built with `unsafe-headers`; CSP disabled (`"csp": null`) | `web/src-tauri/Cargo.toml`, `web/src-tauri/tauri.conf.json` |
| 13 | Rollout constraints | Bundle identifier `com.tacogips.kaiba`; shell crate and `tauri.conf.json` version track the Swift package version | `web/src-tauri/tauri.conf.json`, `web/src-tauri/Cargo.toml`, `Sources/AppCore/Version.swift` |
| 14 | Rollout constraints | Platform floors macOS 14 and iOS 17 | `web/src-tauri/tauri.conf.json` (`bundle.macOS`/`bundle.iOS` `minimumSystemVersion`), `web/src-tauri/gen/apple/project.yml` (`deploymentTarget.iOS`) |
| 15 | Rollout constraints | `productName` is still `Kaiba` — the unresolved collision the design records; must **not** be renamed in this change set | `web/src-tauri/tauri.conf.json`, `web/src-tauri/gen/apple/project.yml` |
| 16 | Rollout constraints | Both ignore files exist and carry the rules the design attributes to them | root `.gitignore` (`web/src-tauri/target/`, `gen/apple/build/`, `gen/schemas/`, pre-existing `*.xcodeproj/`), `web/src-tauri/gen/apple/.gitignore` (`Externals/`, `xcuserdata/`, `build/`) |
| 17 | Build surfaces | The five named client tasks exist: `tauri:dev`, `tauri:build`, `tauri:ios:init`, `tauri:ios:dev`, `tauri:ios:build`, plus the `tauri:check` gate | `mise.toml` |
| 18 | Build surfaces | Vite dev server pinned to port 1420 with `strictPort`, binding a non-loopback host only when `TAURI_DEV_HOST` is set | `web/vite.config.ts` |

Rows 5, 12 and 15 encode divergences the design accepted deliberately: the
login hint is runtime-unaware, `unsafe-headers` is broader than today's needs,
and `csp` is null. Audit them as *present as designed* — do not fix them here.
They are carried forward as recorded deferrals in TASK-005.

**Completion Criteria**:

- [x] All 18 rows walked, each recorded in the progress log as `confirmed`
      or with the fix applied. No row left unstated.
- [x] Any row that fails is fixed in the implementation before TASK-003 runs,
      so the gates cover the corrected tree.
- [x] Rows 5, 12 and 15 are recorded as accepted divergences, not fixed.
- [x] The audit is evidence-based: a row is `confirmed` only after the cited
      file was opened, never from the deliverable checkboxes.

### TASK-001: README naming caveat

**Parallelizable**: Yes (write scope: `README.md`)

**Dependencies**: none

Edit the existing "macOS and iPhone clients" section (`README.md:174-194`),
which today tells a reader to run `mise run tauri:build` with no warning. Add
prose after the code block stating that `mise run tauri:build` emits
`Kaiba.app`, the same installed name the Homebrew Cask uses for the resident
menu-bar app (`dev.kaiba.Kaiba`), that the identifiers differ so nothing is
overwritten, and that the client bundle is build output only and must not be
copied into `/Applications` under the current name. Do not restate the whole
design rationale; point at `design-docs/specs/tauri-client-apps.md`.

**Completion Criteria**:

- [x] The caveat sits in the same section as the `mise run tauri:build`
      instruction, not elsewhere in `README.md`.
- [x] The text names both bundle identifiers and says the client is not
      installed to `/Applications`.
- [x] No change to the existing commands or the endpoint guidance.

### TASK-002: Menu-bar spec back-reference

**Parallelizable**: Yes (write scope: `design-docs/specs/macos-menu-bar-app.md`)

**Dependencies**: none

Addresses the Step 3 low finding: the collision is documented in
`tauri-client-apps.md` and `architecture.md` but not in the spec that owns the
Cask-installed `Kaiba.app`. Add a one-line pointer near the Cask/app-name
material (`macos-menu-bar-app.md:9` Summary bullet, or the Cask staging text
around lines 95-99 and 129) noting that
`design-docs/specs/tauri-client-apps.md` describes a second, undistributed
`Kaiba.app` build output, so anyone changing the Cask or bundle naming here
sees the conflict.

**Completion Criteria**:

- [x] A pointer to `design-docs/specs/tauri-client-apps.md` exists at the
      naming/Cask location in `macos-menu-bar-app.md`.
- [x] Documentation only; no Cask, script, or bundle change.

### TASK-003: Close the serverEndpoint coverage gap, then run the validation gates

**Parallelizable**: No (must run after TASK-000/001/002 land, before staging)

**Dependencies**: TASK-000, TASK-001, TASK-002

**Write scope**: `web/src/notes/serverEndpoint.test.ts` only, plus any
implementation fix a genuine gate failure demands.

#### Step 1 — add the missing `resolveServerRequest` cases

`web/src/notes/serverEndpoint.test.ts` today has five tests covering
normalization, rejection, storage fallback, relative-path resolution, and
runtime detection. Three contracts the design states explicitly under
Transport boundary are unasserted, so a later edit to `resolveServerRequest`
that strips a query or normalizes an absolute URL would pass
`mise run web:check` silently. Add:

- `resolveServerRequest('/note/events?since=1', endpoint)` keeps the query.
  This is the live shape `web/src/notes/events.ts` dispatches, so losing it
  breaks the long-poll feed on native clients.
- An absolute `https://other.test/graphql` input is returned as its own
  target, not re-resolved against the configured endpoint.
- A non-string `RequestInfo`/`URL` input is returned untouched (identity, not
  merely equal).

Keep the existing five tests intact — this is added coverage, not a rewrite.
Place the new assertions in the existing `native server endpoint` describe
block, following the file's current `bun:test` style.

#### Step 2 — run the gates

Run, in order, and capture the outcome of each:

- `mise run web:check` — typecheck, test, lint, build for `web/`.
- `mise run tauri:check` — `cargo fmt --check`, `cargo check`,
  `clippy -D warnings` for the shell crate.
- `mise run test` — the Swift suites.

`bun` comes from mise. Run the Swift suite **through mise**: the `test` task
sets `PKG_CONFIG_PATH = "{{config_root}}/.build/anydoc-native/host/pkgconfig"`
itself (`mise.toml:73-74`) and its `depends = ["anydoc:native"]`
(`mise.toml:53`) produces that directory. Do not export `PKG_CONFIG_PATH` in
the shell and do not edit the task — an outer value shadows the task env with
a path that may not exist.

**Completion Criteria**:

- [x] The three new `resolveServerRequest` assertions exist and pass; the
      original five tests are unchanged and still pass.
- [x] All three commands exit zero with their output recorded in the progress
      log (Swift test count included).
- [x] No test was skipped, weakened, deleted, or marked expected-failure to
      reach a pass. A genuine failure is fixed in the implementation, not in
      the test.
- [x] `bun test src` inside `web:check` actually executed
      `web/src/notes/serverEndpoint.test.ts` — confirm it appears in the run,
      not silently unmatched. It uses `bun:test` like the other 20 `src`
      suites, so the convention is already correct; this is a false-green
      guard, not an expected failure.
- [x] `mise run test` was invoked through mise with no `PKG_CONFIG_PATH` set
      in the calling environment.
- [x] Full macOS/iPhone bundle builds (`tauri:build`, `tauri:ios:build`) are
      NOT gates here — that question is Pending in the user-qa doc.

### TASK-004: Stage the change set

**Parallelizable**: No

**Dependencies**: TASK-003

Stage in this order so the ignore rules are in the index before the trees they
exclude:

1. `.gitignore` and `web/src-tauri/gen/apple/.gitignore`.
2. `web/src-tauri/` — `Cargo.toml`, `Cargo.lock`, `build.rs`, `src/lib.rs`,
   `src/main.rs`, `tauri.conf.json`, `capabilities/default.json`, `icons/`
   (the Tauri-generated icon set; it ships 17 Android files under
   `icons/android/**` alongside the 35 macOS/iOS icons — they are intentional
   generator output, staged as part of the set, and are not an unrelated
   sweep even though the product has no Android target),
   and the `gen/apple/` XcodeGen inputs (`project.yml`, `Podfile`,
   `ExportOptions.plist`, `LaunchScreen.storyboard`, `Assets.xcassets/`,
   `kaiba-client_iOS/Info.plist` and `kaiba-client_iOS.entitlements`,
   `Sources/kaiba-client/main.mm`,
   `Sources/kaiba-client/bindings/bindings.h`).
3. `web/src/notes/serverEndpoint.ts`, `web/src/notes/serverEndpoint.test.ts`,
   `web/src/components/ServerConnectionSettings.tsx`.
4. The 15 modified tracked files from intake (`.gitignore`, `README.md`,
   `design-docs/specs/architecture.md`, `mise.toml`, `web/bun.lock`,
   `web/eslint.config.js`, `web/index.html`, `web/package.json`,
   `web/src/chatbook.css`, `web/src/notes/client.ts`,
   `web/src/notes/events.ts`, `web/src/styles.css`,
   `web/src/views/ConfigView.tsx`, `web/src/views/LoginView.tsx`,
   `web/vite.config.ts`).
5. `design-docs/specs/tauri-client-apps.md`,
   `design-docs/user-qa/tauri-client-apps.md`, and
   `design-docs/specs/macos-menu-bar-app.md` from TASK-002. The last is a
   deliberate 16th tracked file beyond the 15 named at intake: it documents
   this change set's name collision, so it belongs to the Tauri client work
   and is not an unrelated sweep.

Never stage: `web/src-tauri/target/`, `web/src-tauri/gen/schemas/`,
`web/src-tauri/gen/apple/build/`, `web/src-tauri/gen/apple/Externals/`,
`web/src-tauri/gen/apple/kaiba-client.xcodeproj/`, any `xcuserdata/`.

Do not rename `tauri.conf.json` `productName` during close-out: it rewrites
`PRODUCT_NAME` in the tracked `gen/apple/project.yml` and requires a paired
`mise run tauri:ios:init` in the same commit. The final name is a Pending
user decision.

**Completion Criteria**:

- [x] Run **before** any `git add`: `git status --porcelain
      --untracked-files=all web/src-tauri` yields 88 stageable paths (the
      count observed at plan time) and nothing from the never-stage list. The
      local ignore rules already produce this, so a non-empty intersection
      means a rule is missing. After staging, the same command reports those
      paths as `A `, so the count is a pre-stage baseline only.
- [x] `git diff --cached --name-only` contains no unrelated file — nothing
      outside the Tauri client work and the plan relocation.
- [x] Both `.gitignore` files are in the same index as the trees they exclude.

### TASK-005: Relocate the plan, commit, push

**Parallelizable**: No

**Dependencies**: TASK-004

The plan file is untracked, so `git mv` from an untracked path will fail
against the index; move the file to `impl-plans/completed/tauri-client-apps.md`
and `git add` it at the new path. Flip **Status** to `Completed` and check the
remaining deliverable boxes before staging. Commit on `main` per the AGENTS.md
commit policy: describe the shared-client architecture, the Tauri transport
boundary, the Rust shell and Apple inputs, the ignore-rule split, and the
unresolved naming/release TODOs. No AI attribution or co-authorship line.
Then push.

**Completion Criteria**:

- [x] `impl-plans/active/tauri-client-apps.md` no longer exists;
      `impl-plans/completed/tauri-client-apps.md` is tracked.
- [x] Working tree is clean apart from the ignored generated paths.
- [x] `main` is pushed and `git log origin/main -1` shows the commit.
- [x] Commit message records all six unresolved items, because the AGENTS.md commit
      policy requires a commit to describe its unresolved TODOs. Three are Pending in
      `design-docs/user-qa/tauri-client-apps.md`: client name and release
      channel, build-gate scope, plaintext-`http` endpoint policy. Three are
      deferrals the accepted design states in prose:
      1. The login-screen hint prints `kaiba client issue --name "Kaiba Web"`
         in every runtime (`web/src/views/LoginView.tsx:75`), contradicting the
         `Kaiba App` registration label at `web/src/notes/client.ts:66`;
         making the hint runtime-aware is a follow-up.
      2. `unsafe-headers` on `tauri-plugin-http` (`web/src-tauri/Cargo.toml`)
         is broader than the client needs — it sets only `Authorization` and
         `Content-Type` — and should be dropped if no native request comes to
         require a restricted header.
      3. `"csp": null` in `web/src-tauri/tauri.conf.json`; a CSP must be
         defined before the client renders any HTML it did not author.

## Dependencies

TASK-000, TASK-001 and TASK-002 are mutually independent and all precede
TASK-003. TASK-003 precedes TASK-004, which precedes TASK-005. TASK-000 must
finish before TASK-003 so any audit fix is covered by the gates; TASK-003 must
not run before the documentation edits, so the gates cover the tree that is
actually committed.

## Parallelizable Tasks

TASK-000 (read-only audit), TASK-001 (`README.md`) and TASK-002
(`design-docs/specs/macos-menu-bar-app.md`) have disjoint write scopes and may
run concurrently. TASK-003, TASK-004 and TASK-005 are strictly sequential.

## Verification

- `mise run web:check`
- `mise run tauri:check`
- `mise run test` (invoked through mise; the task supplies `PKG_CONFIG_PATH`)
- `git status --porcelain --untracked-files=all` (post-commit cleanliness)

## Completion Criteria

- [x] Every one of the 18 TASK-000 audit rows is recorded as confirmed or fixed.
- [x] The three new `resolveServerRequest` assertions pass alongside the
      original five.
- [x] The three gates exit zero with no test weakened or skipped.
- [x] The plan lives at `impl-plans/completed/tauri-client-apps.md` with
      **Status: Completed** and every deliverable checked.
- [x] The Tauri client change set plus the plan relocation is committed to
      `main` and pushed, with no unrelated file in the commit.

## Progress-Log Expectations

Append a dated entry per task. TASK-000 records all 18 rows with their verdict.
TASK-003 records each gate's command and outcome, including the Swift test
count and confirmation that `serverEndpoint.test.ts` executed. TASK-004 records
the pre-stage path count. TASK-005 records the commit SHA and the push.

## Risks

- **Audit surfaces real drift.** TASK-000 may find a design statement the tree
  does not satisfy; the fix then lands before the gates, which is why TASK-000
  precedes TASK-003. Spot checks at plan time passed on all 18 rows, so this is
  a guard rather than an expected finding.
- **Never-executed gates.** The three gates have not run against this tree.
  `web:check` includes lint and build, so an uncommitted-but-unlinted file may
  fail on first run. Fix forward in the implementation.
- **Shadowed `PKG_CONFIG_PATH`.** Exporting it in the calling shell overrides
  the value `mise.toml:73-74` sets for the `test` task and breaks the Swift
  build. Run through mise and leave the environment alone.
- **Ignore-rule blind spot.** Locally, git honors the uncommitted `.gitignore`,
  so staging looks correct today; the failure only appears in a fresh clone or
  CI. Staging both ignore files first is the mitigation.
- **Nested `.gitignore` omission.** `web/src-tauri/gen/apple/.gitignore` is the
  only source of the `Externals/` and `xcuserdata/` rules and is untracked; a
  glob-based `git add` of tracked paths alone would drop it.
- **Name collision unresolved.** `Kaiba.app` is claimed by two artifacts. The
  caveat is a documentation mitigation, not a fix; distribution stays blocked
  on the Pending user decision.
- **Plaintext bearer.** A non-loopback `http` endpoint sends the bearer in the
  clear. Accepted residual risk for this release; recorded as Pending. Requests
  leave through the Rust shell rather than `URLSession`, so iOS App Transport
  Security never applies and the OS raises no warning.
- **Credential bound to its issuing origin (closed, post-close-out).** Step 7's
  adversarial review found that `saveServerEndpoint` persisted a new origin
  without clearing the bearer the previous server issued, so repointing the
  client sent server A's credential to server B. The client's only clear-on-failure path is
  a 401 from the GraphQL route (`client.ts:705`), which does not cover the
  long poll, attachment fetches or the agent-stream poll, and a
  `kaiba serve --allow-unauthenticated` host never emits 401 at all
  (`Sources/AppServer/ServerContracts.swift:245`, `:343`, `:382`), so the
  disclosure was persistent rather than one-time. The first fix (`5ed5090`)
  deleted the bearer on origin change, which satisfied the invariant but made a
  mistyped endpoint an unrecoverable logout; the shipped behavior instead
  scopes the credential per origin under
  `kaiba-note-bearer:<normalized endpoint>`, so a bearer is unreadable for any
  host that did not issue it and correcting a typo restores the session. The
  401 path must not be described as a general backstop.

## Progress Log

- 2026-08-29: Deliverables 1-4 implemented in the working tree, uncommitted.
- 2026-08-29: Design accepted at Step 3 (`needs_revision: false`), with two
  low findings: no back-reference from `macos-menu-bar-app.md`, and no
  `Kaiba.app` caveat in the staged `README.md` section.
- 2026-08-29: Plan rewritten to the repository template and re-scoped to the
  residual close-out (TASK-001..005). Deliverable 5 remains unexecuted.
- 2026-08-29: Step 4 self-review — four low precision defects fixed in place:
  exact `gen/apple/Sources/kaiba-client/` paths, the 88-path check declared
  pre-stage, a false-green guard that `serverEndpoint.test.ts` really ran, and
  `macos-menu-bar-app.md` named as a deliberate 16th tracked file. No design
  defect found; the plan claims no architecture the accepted spec does not
  state.
- 2026-08-29: Step 5 review returned `needs_revision` with two mid and two low
  findings. Revised: added TASK-000, a 16-row deliverable audit mapping every
  design section to file evidence, and stated that the pre-checked deliverable
  boxes do not satisfy acceptance criterion 1; extended TASK-003 with the three
  missing `resolveServerRequest` test cases ahead of the gates; replaced the
  `PKG_CONFIG_PATH` hedge with the `mise.toml:73-74` / `anydoc:native` fact and
  a do-not-override instruction; extended TASK-005's commit criterion from
  three Pending items to all six unresolved items, adding the runtime-unaware
  `Kaiba Web` login hint, the conditional `unsafe-headers` removal, and the CSP
  precondition.
- 2026-08-29: Step 4 self-review of the revised plan — verified every cited line
  reference against the tree (`README.md:174-194` is the client section,
  `macos-menu-bar-app.md` mentions `Kaiba.app` at lines 9/95/98/129,
  `mise.toml:53` and `:73-74` are the `depends` and `PKG_CONFIG_PATH` lines,
  `git status --porcelain --untracked-files=all web/src-tauri` still yields 88).
  One plan-only defect fixed: the audit table omitted the design's Build
  surfaces section, leaving `mise.toml` and `web/vite.config.ts` — both files
  in the commit — with no audit row. Added rows 17-18 for the five client
  tasks and the port-1420/`strictPort`/`TAURI_DEV_HOST` dev-server pinning.
  No design defect found.
- 2026-08-29: Step 5 review accepted the plan (`needs_revision: false`) with two
  low plan-only findings, both fixed before implementation: the Risks section's
  stale "all 16 rows" corrected to "all 18 rows", and TASK-004's `icons/` entry
  expanded to state that the 17 `icons/android/**` files are intentional Tauri
  generator output shipped with the icon set, so the "no unrelated file" check
  resolves without an ad-hoc judgment.
- 2026-08-29: TASK-000 deliverable audit executed. Every cited file was opened;
  all 18 rows confirmed, no row failed, so no pre-gate fix was required:
  1 confirmed - `serverEndpoint.ts` `serverRequest` returns `fetch(input, init)`
  when `isTauriRuntime()` is false and otherwise dynamically imports
  `@tauri-apps/plugin-http`; runtime detection is the only switch.
  2 confirmed - `resolveServerRequest` falls back to `new URL(input, base)`
  against `normalizeServerEndpoint(endpoint) + '/'`, so relative paths resolve
  and query strings survive (now asserted, TASK-003).
  3 confirmed - `new URL(input).toString()` returns an absolute input as its own
  target, and `typeof input !== 'string'` returns the input by identity.
  4 confirmed - `events.ts:2` imports `serverRequest` and `:41` uses it as the
  default `fetchImpl` for the `/note/events` long poll.
  5 confirmed as accepted divergence - `client.ts:66` sends
  `isTauriRuntime() ? 'Kaiba App' : 'Kaiba Web'`; the login hint at
  `LoginView.tsx:75` prints `Kaiba Web` in every runtime. Not fixed here.
  6 confirmed - `normalizeServerEndpoint` rejects non-`http(s)` schemes,
  credentials, query/fragment and any path beyond `/`, returning the origin with
  the trailing slash stripped.
  7 confirmed - `readServerEndpoint` returns `defaultServerEndpoint` on absent
  storage and catches a normalization throw rather than propagating it.
  8 confirmed - `defaultServerEndpoint = 'http://127.0.0.1:8787'`.
  9 confirmed - `ServerConnectionSettings.tsx` wraps the whole form in
  `<Show when={isTauriRuntime()}>`, takes a `compact` prop, and calls
  `window.location.reload()` after `saveServerEndpoint`; mounted at
  `ConfigView.tsx:65` and `LoginView.tsx:70` (`compact`).
  10 confirmed - `index.html:5` carries `viewport-fit=cover`; `styles.css:5`
  pads the body with all four `env(safe-area-inset-*)` values; no phone branch.
  11 confirmed - `capabilities/default.json` grants `http:default` with
  `http://**` and `https://**` on `windows: ["main"]`.
  12 confirmed as accepted divergence - `Cargo.toml` builds `tauri-plugin-http`
  with `unsafe-headers`; `tauri.conf.json` sets `"csp": null`. Not fixed here.
  13 confirmed - identifier `com.tacogips.kaiba`; `tauri.conf.json` version
  `0.1.9` = `Cargo.toml` `0.1.9` = `Sources/AppCore/Version.swift` `0.1.9`.
  14 confirmed - `bundle.macOS.minimumSystemVersion` `14.0`,
  `bundle.iOS.minimumSystemVersion` `17.0`, `project.yml` `deploymentTarget.iOS`
  `17.0`.
  15 confirmed as accepted divergence - `productName` is `Kaiba` and
  `project.yml` `PRODUCT_NAME: Kaiba`. Deliberately not renamed.
  16 confirmed - root `.gitignore` carries `web/src-tauri/target/`,
  `web/src-tauri/gen/apple/build/`, `web/src-tauri/gen/schemas/` and the
  pre-existing `*.xcodeproj/` (line 9); `gen/apple/.gitignore` carries
  `xcuserdata/`, `build/`, `Externals/`.
  17 confirmed - `mise.toml` defines `tauri:check` (110), `tauri:dev` (118),
  `tauri:build` (125), `tauri:ios:init` (132), `tauri:ios:dev` (139),
  `tauri:ios:build` (146).
  18 confirmed - `vite.config.ts` pins `port: 1420` with `strictPort: true` and
  `host: process.env.TAURI_DEV_HOST || false`.
- 2026-08-29: TASK-001 done. The `README.md` "macOS and iPhone clients" section
  now ends with the naming caveat: `mise run tauri:build` emits `Kaiba.app`, the
  same installed name as the Cask menu-bar app; identifiers `com.tacogips.kaiba`
  vs `dev.kaiba.Kaiba` differ so nothing is overwritten; the client bundle is
  build output only and must not be copied into `/Applications` under the
  current name; pointer to `design-docs/specs/tauri-client-apps.md`. Commands
  and endpoint guidance unchanged.
- 2026-08-29: TASK-002 done. `design-docs/specs/macos-menu-bar-app.md` Summary
  bullet (the `Kaiba.app` Cask bullet at line 9) now back-references
  `design-docs/specs/tauri-client-apps.md` as the second, undistributed
  `Kaiba.app`. Documentation only; no Cask, script or bundle change.
- 2026-08-29: TASK-003 done. Three assertions added to the existing
  `native server endpoint` describe block in `serverEndpoint.test.ts`: query
  preserved on `/note/events?since=1`, absolute `https://other.test/graphql`
  kept as its own target, and a `URL` instance returned by identity (`toBe` on
  the same object). The original five tests are untouched. Gates, all exit 0,
  nothing skipped or weakened:
  `mise run web:check` -> tsc clean; `bun test src` 145 pass / 0 fail across 21
  files; vitest 8 pass / 4 files; eslint clean; vite build ok. False-green
  guard: `bun test src --test-name-pattern "native server endpoint"` ran 8 tests
  / 0 fail (5 original + 3 new), proving `serverEndpoint.test.ts` is matched by
  the same `src` pattern `web:check` uses.
  `mise run tauri:check` -> exit 0 (`cargo fmt --check`, `cargo check`,
  `clippy -D warnings`).
  `mise run test` -> exit 0; 523 XCTest cases with 0 failures plus a
  swift-testing run of 34 tests, 25.4s. Invoked through mise with
  `PKG_CONFIG_PATH` unset in the calling shell, so the task's own
  `mise.toml:73-74` value applied.
- 2026-08-29: TASK-004 done. Pre-stage baseline re-confirmed before any
  `git add`: `git status --porcelain --untracked-files=all web/src-tauri`
  returned exactly 88 paths, and the never-stage grep (`src-tauri/target/`,
  `gen/schemas/`, `gen/apple/build/`, `gen/apple/Externals/`,
  `kaiba-client.xcodeproj/`, `xcuserdata/`) returned nothing. Staged in plan
  order: both ignore files first, then `web/src-tauri/`, then the new `web/src/`
  files, then the 15 modified tracked files, then the three design docs
  (`macos-menu-bar-app.md` as the deliberate 16th tracked file).
- 2026-08-29: TASK-005 done. Plan relocated from `impl-plans/active/` to
  `impl-plans/completed/tauri-client-apps.md` (copied and `git add`-ed at the
  new path, since the source file was untracked and `git mv` cannot move an
  untracked path through the index), Status flipped to Completed, all
  deliverable and criteria boxes checked. Committed on `main` and pushed; the
  commit message records all six unresolved items (three Pending user-qa
  decisions plus the three accepted design deferrals). The commit SHA and the
  push confirmation are appended below.
- 2026-08-29: Close-out commit is `1d93eba` ("Add Tauri macOS and iPhone
  clients for the existing SolidJS note client"), 110 files changed, pushed to
  `origin/main` (`08c4843..1d93eba`). This progress-log line recording the SHA
  necessarily lands in a follow-up commit, since the SHA does not exist until
  the change-set commit is written.
- 2026-08-29: Step 7 adversarial review returned `needs_revision` with one mid
  finding and no high finding: `web/src/notes/serverEndpoint.ts:49`
  `saveServerEndpoint` persisted a new origin without clearing the bearer at
  `kaiba-note-bearer`, so a user repointing the client from server A to server B
  leaked A's credential to B on every request, persistently for an
  `--allow-unauthenticated` host. Fixed inside TASK-003's write scope plus the
  two modules the fix requires:
  `web/src/notes/serverEndpoint.ts` now exports `serverCredentialStorageKey`,
  requires `removeItem` on `EndpointStorage` (with `availableEndpointStorage`
  checking for it), and clears the credential in `saveServerEndpoint` when
  `readServerEndpoint(storage)` differs from the newly normalized origin --
  which also covers moving off the default `http://127.0.0.1:8787` with no
  stored value. `web/src/notes/client.ts` now imports that key instead of
  redeclaring the `'kaiba-note-bearer'` literal; the dependency runs
  client -> serverEndpoint, so no import cycle is introduced.
  `web/src/notes/serverEndpoint.test.ts` gains three cases (drop on origin
  change, drop when moving off the default, keep on same-origin re-save) and
  its `memoryStorage` helper gains `removeItem` and an optional seeded
  credential. Mutation-checked: reverting only the clear makes 2 of the 3 new
  tests fail, so they are load-bearing rather than tautological.
  `design-docs/specs/tauri-client-apps.md` records the credential-bound-to-
  origin invariant and drops the "self-heals on 401" framing the review
  rejected, and adds the ATS note. The two Step 7 lows (untested `serverRequest`
  branch selection, untested `ServerConnectionSettings.tsx`) are confirmed
  scoped plan decisions and were not changed. Gates after the fix:
  `mise run web:check` exit 0 (`bun test src` 148 pass / 0 fail, up from 145),
  `mise run tauri:check` exit 0.
- 2026-08-29: Commit range for this close-out, recorded so an audit or revert
  covers the whole change set rather than the first commit only:
  `1d93eba` the Tauri client change set (110 files);
  `53be83c` the plan progress log recording `1d93eba`;
  `5ed5090` the first credential fix (cleared the bearer on origin change);
  `0c52dbf` the credential-scoping revision, the tail of the range.
  The full close-out is therefore `08c4843..0c52dbf`.
  `5ed5090` and the revision changed a security-relevant behavior contract, so
  reverting `08c4843..1d93eba` alone would leave credential handling for a
  transport that no longer exists.
- 2026-08-29: Step 7 adversarial review of `1d93eba`/`53be83c`/`5ed5090`
  returned one mid finding and no high finding: `5ed5090` satisfied the
  credential invariant destructively. `saveServerEndpoint` deleted the only
  bearer the app held on any syntactically valid origin change, so one mistyped
  character (`notes.exmaple.com` passes `normalizeServerEndpoint` and
  `input type="url"`) logged the user out with no confirmation, no reachability
  check and no undo, recoverable only by pasting a key issued on the server
  host. Fixed by taking the non-destructive option the review preferred:
  credentials are now scoped per origin. `serverEndpoint.ts` adds
  `serverCredentialKey(endpoint)` (`kaiba-note-bearer:<normalized endpoint>`)
  and `currentServerCredentialKey(storage?)`; `saveServerEndpoint` no longer
  deletes anything and instead files a pre-scoping unscoped value under the
  outgoing origin when the endpoint changes. `client.ts` reads, writes and
  clears through `readBearer`/`storeBearer`/`dropBearer`, which use the key for
  the endpoint in effect and migrate a pre-scoping value on first read so an
  existing install keeps its session. `serverEndpoint.test.ts` replaces the
  three destruction cases with five scoping cases, including typo-then-correct
  recovery; `client.test.ts` derives its two credential-key literals from
  `currentServerCredentialKey`; new
  `web/src/components/ServerConnectionSettings.integration.tsx` covers the
  submit handler end to end (native-only rendering, per-origin credential
  survival across a switch and back, invalid-URL failure message, reload called
  exactly once per successful save and never on failure). The design doc now
  states the scoping behavior and why destruction was rejected. Two Step 7 lows
  are deliberately not taken and remain open: resolving `URL`/`Request` inputs
  in `resolveServerRequest` (latent, every caller passes a string) and an
  eslint `no-restricted-syntax` guard on `innerHTML`/`iframe` to mechanically
  enforce the `"csp": null` precondition. Gates: `mise run web:check` exit 0
  (`bun test src` 150 pass / 0 fail, vitest 11 pass / 5 files),
  `mise run tauri:check` exit 0.
