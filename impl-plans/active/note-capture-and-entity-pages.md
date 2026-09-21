# Anywhere Capture and Entity Pages

**Status**: In Progress (implementation run; starting material `ba7ef12` under
line-by-line review — TASK-000)
**Design Reference**: `design-docs/specs/note-capture-and-entity-pages.md`

## Purpose

Implement F1 Anywhere Capture (`POST /note/capture` into a kind-tag-singleton
Quick Memos notebook, with an SPA capture page) and F2 Entity Pages
(`tags.canonical_note_id` promote/unpromote plus co-occurring tags on the
existing tag mode), as one work package. All decisions, contracts and rejected
alternatives live in the design document; tasks below only carve it into
ordered, verifiable deliverables.

## Applicable prior knowledge

Team knowledge-base recall for this topic returned no entries. Local
environment facts implementers must apply:

- Plain `swift build`/`swift test` fail linking `anydoc_ffi`. Build with
  `mise run build`; for tests export
  `PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig` then
  `mise exec -- swift test`.
- `bun` comes from mise, not PATH. Web checks run in `web/`:
  `tsc --noEmit`, `bun test src`, `bun run lint`, `bun run build`.
- This repository is public: never commit machine-local absolute paths.
- Swift gotcha: an overload added for protocol conformance that calls a
  same-named method can recurse into itself (silent OOM SIGKILL). Name
  internal cores distinctly.
- 2026-09-21 implementation run additions (team KB recall for
  `note-capture-entity-pages` again returned zero entries):
  - Every Swift command must run through an arm64 login shell — the default
    shell is Rosetta and the xctest bundle refuses to dlopen there. Combined
    with the anydoc prerequisite the working sequence is:
    `arch -arm64 /bin/zsh -lc 'mise run anydoc:native'` once, then
    `arch -arm64 /bin/zsh -lc 'export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig; swift build && swift test'`
    (verified: that login shell has swift 6.3.3 arm64, mise, and mise-managed
    bun; `.build/anydoc-native/host/pkgconfig` does not exist until
    `anydoc:native` runs).
  - Test-baseline protocol: the suite's health at branch point `bab58cd`
    (merge-base with main) is unknown. Before calling any failure
    pre-existing, run the same `--filter` on a clean checkout of `bab58cd`
    and record both results; never label a failure environmental without
    that evidence.
  - AGENTS.md commit policy: no AI attribution or co-authorship lines in
    commit messages; no emojis in any output; this repository is public —
    never commit machine-local absolute paths.
  - `origin` has no `feat/note-capture-and-entity-pages` yet: the first
    `git push -u origin feat/note-capture-and-entity-pages` creates it. Never
    push main; never force push. The untracked `.riela/` directory is riela
    runtime state and must never be committed.
- 2026-09-21 resumed-run analysis additions (prior run killed by an external
  OOM; team KB recall for `note-capture-entity-pages` again returned zero
  entries):
  - The tree at `b5226d2` builds and its targeted suites pass:
    `arch -arm64 /bin/zsh -lc 'mise run anydoc:native'` exit 0;
    `arch -arm64` `swift build` exit 0 (4.71s, warm cache left by the killed
    run); `swift test --filter
    "QuickMemo|NoteCaptureRoute|TagEntity|NoteStoreSchema|NoteGraphQLSchemaInventory"`
    exit 0, 76 tests / 0 failures. This is analysis evidence only — it does
    NOT waive TASK-000: those tests were written by the same overrunning run
    and must themselves be reviewed against the design before any checkbox
    credit.
  - Web naming collision: `web/src/components/NoteCapture.tsx` already exists
    as an unrelated inline per-notebook composer (pre-existing, commit
    `2035fda`), and the `canonical` map in `web/src/notes/controller.ts` is a
    notebook read-only cache. Neither implements any part of F1/F2 and
    neither may be repurposed.

## Starting material (2026-09-21)

Commit `ba7ef12` ("wip: unreviewed F1/F2 implementation from an overrunning
planning run") is the only delta between this branch and main (24 files,
+3209/−14). It has never been built, tested or reviewed. Coverage map from the
implementation-run analysis:

- Candidate implementations exist for TASK-001..006 (schema v20 + quick-memo
  seed, `NoteService+QuickMemo.swift`, `NoteService+TagDetail.swift` +
  `NoteService+ActionHistory.swift` undo snapshot, capture route + SPA
  rewrite, GraphQL surface, CLI surface) with test files for each.
- Entirely absent: TASK-007 (web capture view), TASK-008 (TagPane entity
  header), TASK-009 (`kaiba-note.md` row + verification sweep). No `web/src`
  path is touched by the commit.
- The commit also amended design decision E1 (undo snapshot
  `canonicalTagIds`, unfiltered `idx_tags_canonical_note`); that delta was
  ratified by design review — see the progress log and the design doc Status.

TASK-000 below gates everything: no TASK-001..006 checkbox may be checked on
the strength of `ba7ef12` until its file has passed line-by-line review, and
the keep/correct/remove outcome is recorded in the progress log.

## Deliverables

- [x] TASK-000 review: every `ba7ef12` file verified against the design;
      keep/correct/remove log recorded in the progress log (evidence:
      `tmp/note-capture-entity-pages-20260921-opus3/TASK-000/progress.md`,
      summarized in the 2026-09-21 resumed-run progress-log entries below)
- [ ] Schema v20: `tags.canonical_note_id` column and
      `notebook-kind:quick-memo` seed (`Sources/AppCore/NoteStoreSchema.swift`)
- [ ] `NoteService.ensureQuickMemoNotebook()` / `captureQuickMemo(...)`
- [ ] `NoteService` promote/unpromote + `coOccurringTags` (TagDetail extension)
- [ ] `POST /note/capture` route + `GET /note/capture` SPA rewrite
      (`Sources/AppServer/ServerContracts.swift`,
      `Sources/AppServer/KaibaStaticAssetResolver.swift`)
- [ ] GraphQL: extended `tagDetail`, `promoteTagNote`, `unpromoteTagNote`
      (`Sources/AppGraphQL/`)
- [ ] CLI: `kaiba tag promote|unpromote`, enriched `kaiba tag <name>`
      (`Sources/AppCore/CommandTags.swift`, `Command.swift` help text)
- [ ] Web viewer: capture view + TagPane entity header (`web/src/`)
- [ ] Tests for every layer above; spec docs cross-referenced

## Tasks

Task table (primary write scope is exclusive to the task; `sharedPaths` edits
are reconciled serially in dependency order):

| Task | Deliverable | Primary write scope | Depends on | Parallelizable |
| --- | --- | --- | --- | --- |
| TASK-000 | Review of starting material `ba7ef12` (build + line-by-line vs design) | none (read + progress log; repairs land inside the owning task) | — | No (wave 0, gates all) |
| TASK-001 | Schema v20 + quick-memo kind seed | `Sources/AppCore/NoteStoreSchema.swift`, `Tests/AppCoreTests/NoteStoreSchemaCanonicalTests.swift` (new) | — | No (wave 1, shared root of everything) |
| TASK-002 | Quick Memos service (`ensureQuickMemoNotebook`, `captureQuickMemo`) | `Sources/AppCore/NoteService+QuickMemo.swift` (new), `Tests/AppCoreTests/QuickMemoCaptureTests.swift` (new) | TASK-001 | Yes, with TASK-003 |
| TASK-003 | Canonical note + co-occurrence service | `Sources/AppCore/NoteService+TagDetail.swift`, `Tests/AppCoreTests/TagEntityPageTests.swift` (new) | TASK-001 | Yes, with TASK-002 |
| TASK-004 | HTTP capture route + SPA rewrite | `Sources/AppServer/ServerContracts.swift`, `Sources/AppServer/KaibaStaticAssetResolver.swift`, `Tests/AppServerTests/NoteCaptureRouteTests.swift` (new) | TASK-002 | Yes, with TASK-005 |
| TASK-005 | GraphQL surface | `Sources/AppGraphQL/GraphQLContractProjector.swift`, `NoteGraphQLDocumentExecutor.swift`, `NoteGraphQLDocumentExecutorSupport.swift`, `NoteGraphQLDocumentInputs.swift`, `GraphQLNoteSchemaContract.swift`, `Tests/AppGraphQLTests/` (new file) | TASK-003 | Yes, with TASK-004 |
| TASK-006 | CLI surface | `Sources/AppCore/CommandTags.swift`, `Sources/AppCore/Command.swift` (help text only), `Tests/AppCoreTests/` (extend command tests) | TASK-003 | Yes, with TASK-007/008 |
| TASK-007 | Web capture page | `web/src/router.ts`, `web/src/views/` (new capture view), `web/src/state/appStore.tsx`, tests beside them | TASK-004 | Yes, with TASK-006/008 |
| TASK-008 | Web entity header on TagPane | `web/src/components/TagPane.tsx`, `web/src/state/appStore.tsx`, tests beside them | TASK-005 | Yes, with TASK-006/007 |
| TASK-009 | Docs + full verification sweep | `design-docs/specs/kaiba-note.md` (HTTP API section row), this plan's progress log | TASK-001..008 | No (serial reconciliation wave) |

Shared paths needing serial care: `web/src/state/appStore.tsx` (TASK-007 and
TASK-008 — land 007 before 008 or coordinate), `Sources/AppCore/Command.swift`
help text (TASK-006 only). Implementers must take fresh reads before editing
shared files and re-verify after each wave; overlapping edits are repaired
serially, never in parallel.

### Resumed-run ordering (2026-09-21, session-7)

TASK-000..006 are ACCEPTED (two integration-review waves, records at
`tmp/note-capture-entity-pages-20260921-opus4/integration-review/` and
`integration-review-wave2/`; full suite exit 0: XCTest 894 executed /
1 skipped / 0 failures, Swift Testing 135/135). The accepted TASK-002/004/005/006
delta-closure work sits UNCOMMITTED in the working tree and was verified
byte-identical (SHA-256, all eleven files) to the wave-2
`acceptedFileHashesSha256` at session-7 analysis. Remaining execution order:

1. **COMMIT-A** — re-verify the eleven hashes against the wave-2 acceptance
   record; on any mismatch STOP and report (do not repair silently). Then
   commit exactly the ten modified files (explicit paths; never `.riela/`,
   never `tmp/`) with a message describing the C3/C6/E6/F-000-8 delta
   closures. No content edits of any kind in this commit.
2. **TASK-007** then **TASK-008** (serial across the shared
   `web/src/state/appStore.tsx`; each commits its own files when green).
3. **TASK-009** — docs row, plan checkbox sweep with per-box evidence,
   final full Swift + web verification, final commit, then the branch's
   first push (`git push -u origin feat/note-capture-and-entity-pages`).

Accepted-material rule: TASK-001..006 files are frozen. Reopening one
requires a recorded finding, and re-running that task's filter afterward.
Findings RC-7 (the co-occurrence bound `200` appears in both
`NoteService.maximumCoOccurringTagLimit` and the GraphQL input validation)
and RC-8 (MARK ordering) are explicitly DEFERRED as cosmetic: closing them
would reopen accepted files for zero behavior change.

### TASK-000: Review the starting material

**Parallelizable**: No (wave 0; gates every other task)

**Completion Criteria** (all met 2026-09-21; evidence at
`tmp/note-capture-entity-pages-20260921-opus3/TASK-000/`):

- [x] `arch -arm64 /bin/zsh -lc 'mise run anydoc:native'` then
      `arch -arm64 /bin/zsh -lc 'export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig; swift build'`
      succeed (both exit 0; `attempt-1/anydoc-native.log`,
      `attempt-1/swift-build-1.log` "Build complete! (67.25s)"; targeted
      filter ran 76 tests, 0 failures, `attempt-1/swift-test-targeted.log`)
- [x] Every file of `git show ba7ef12` reviewed against design decisions
      C1–C7 / E1–E8 and the C6 contract; per-file keep / correct / remove
      verdicts recorded in `TASK-000/progress.md` §4 (24 files: 20 KEEP,
      4 CORRECT via findings F-000-1..6, 0 REMOVE)
- [x] Anything the design does not call for is deleted (nothing qualified);
      anything wrong is routed to its owning TASK as findings F-000-1..8;
      the E1 delta ratification is confirmed against
      `NoteService+ActionHistory.swift` (`progress.md` §3, including FK
      enforcement and restore ordering)

### TASK-001: Schema v20 — canonical column and quick-memo kind

**Parallelizable**: No

**Completion Criteria**:

- [ ] `tags` DDL carries `canonical_note_id TEXT REFERENCES notes(note_id) ON DELETE SET NULL`
- [ ] `quickMemoNotebookKindTag = "notebook-kind:quick-memo"` constant + stable id, appended to `systemNotebookKindTags`
- [ ] `currentVersion = 20`; fresh store seeds the kind tag; v19 store still refused by `unsupportedLegacyVersion`
- [ ] New tests cover column presence, SET NULL on note deletion, seed, version guard

### TASK-002: Quick Memos capture service

**Parallelizable**: Yes (with TASK-003)

**Completion Criteria**:

- [ ] `ensureQuickMemoNotebook()` mirrors `bootstrapLongTermMemoryNotebook()` (single transaction, singleton invariant error, title `Quick Memos`, system kind tag `deletable: false`)
- [ ] **F-000-2 closed (C3 delta)**: `quickMemoNotebookIds` joins `notebooks` and filters `owner_user_id = writeOwnerUserId() AND library_id = writeLibraryId()`; the multi-holder invariant is per-scope; a second account's capture resolves or creates **its own** notebook. Replace `testASecondAccountCannotCaptureIntoAnotherAccountsQuickMemosNotebook` with per-principal assertions (distinct notebooks per account, each containing only its own captures)
- [ ] **F-000-6 recorded (C4 delta)**: the once-only `notebookCreated` publish stays as implemented; no code change, delta already in the design doc
- [ ] `captureQuickMemo(bodyMarkdown:title:)` routes through `createNote`, returning the created note; auto-action enqueue and change event proven by tests
- [ ] Concurrency/idempotency and duplicate-kind-tag failure tests pass (duplicate-kind-tag scoped per principal)

### TASK-003: Canonical note + co-occurring tags service

**Parallelizable**: Yes (with TASK-002)

**Completion Criteria**:

- [ ] `promoteTagCanonicalNote(tagId:noteId:)` / `unpromoteTagCanonicalNote(tagId:)` with the E2 validation matrix (missing tag/note, folder-class and document-kind rejection, replace semantics, no-op unpromote), publishing change events
- [ ] `coOccurringTags(tagId:limit:)` per E4, excluding system kind and folder tags
- [ ] `tagDetail(tagId:)` payload extended with `canonicalNote` and co-occurrence
- [ ] EXPLAIN QUERY PLAN test asserts `idx_note_tags_tag` use (no full scan)

### TASK-004: `POST /note/capture` + SPA rewrite

**Parallelizable**: Yes (with TASK-005)

**Completion Criteria**:

- [ ] `ServerContracts.route` gains `POST /note/capture` → `routeNoteCapture` implementing the amended C6 contract exactly (201/400/401/405/503/500 bodies)
- [ ] **F-000-1 + F-000-3 closed (C6 delta)**: the `404` arm and `noteCaptureNotebookUnavailableMessage` are deleted (unreachable under the C3 delta) together with `testASecondAccountAnswersAGeneric404ThatNamesNoForeignNotebook`; the blanket `catch NoteServiceError.invalidInput → 400` mapping is removed so a service error on a route-validated request (including the singleton-invariant violation) answers the existing generic 500; the route doc comment states the amended contract; tests pin invariant-failure → 500 and second-account capture → 201 into that account's own notebook
- [ ] `GET /note/capture` serves the SPA bootstrap via the `/note/register` rewrite pattern
- [ ] Route tests cover every status body, authenticated and `--allow-unauthenticated` modes

### TASK-005: GraphQL surface

**Parallelizable**: Yes (with TASK-004)

**Completion Criteria**:

- [ ] `tagDetail` payload exposes `canonicalNote` and `coOccurringTags`; the limit is the root-field argument `coOccurringTagLimit` per the ratified E6 delta (**F-000-4 recorded**; implementation already conforms, no code change for the argument shape)
- [ ] **F-000-5 closed**: the limit is threaded through `NoteService.tagDetail(tagId:coOccurringTagLimit:)` (defaulted parameter) so `NoteGraphQLService+TagEntity.swift` computes the aggregate once on a non-default limit instead of discarding and re-running it
- [ ] `promoteTagNote` / `unpromoteTagNote` mutations return `NoteMutationPayload`; operation allow-lists updated
- [ ] Schema contract doc string (`GraphQLNoteSchemaContract.swift`) updated; executor tests pass

### TASK-006: CLI surface

**Parallelizable**: Yes (with TASK-007/008)

**Completion Criteria**:

- [ ] `kaiba tag promote --tag <name-or-id> --note <note-id>` and `kaiba tag unpromote --tag <name-or-id>` implemented in `CommandTags.swift` following `tag define` conventions
- [ ] `kaiba tag <name-or-id>` prints canonical note and top co-occurring tags
- [ ] **F-000-8 closed**: when the positional argument parses as a `NoteID` and resolves to no tag, the error restores the pre-`ba7ef12` hint (`tag requires --add <name> or --remove <name>`) instead of the bare `tag not found: note-…`; covered by a command test
- [ ] `Command.swift` usage text updated; command tests extended

### TASK-007: Web capture page

**Parallelizable**: Yes (with TASK-006/008)

**Completion Criteria**:

- [ ] New view `web/src/views/CaptureView.tsx` (the name `NoteCapture.tsx` is
      taken by an unrelated pre-existing inline composer in
      `web/src/components/` — do not repurpose or collide with it, nor with
      the `canonical` notebook cache in `web/src/notes/controller.ts`)
- [ ] Boot detection: the SPA is served at path `/note/capture` by the C5
      rewrite while routing is hash-based, so App boot checks
      `location.pathname === '/note/capture'` and renders the capture view;
      registration reuses the existing `?code=` initialize flow and per-origin
      bearer storage in `NoteGraphQLClient`
- [ ] The view renders textarea + submit; posts to `POST /note/capture` with
      the stored bearer credential; success shows the note id and clears;
      a visitor with no stored credential is shown the existing
      unregistered/registration surface, not a new one
- [ ] Vitest coverage for submit, error body rendering, unregistered redirect

**Implementation notes (session-7 fact-finding, verified on disk):**

- The server side is DONE and committed: `kaibaSPABootstrapPaths` in
  `Sources/AppServer/KaibaStaticAssetResolver.swift` already rewrites both
  `/note/register` and `/note/capture` to the SPA bootstrap (RC-5 closed).
- Boot branch: `web/src/App.tsx` currently renders `<ChatbookView />`
  unconditionally inside `AppStoreProvider`; add the
  `location.pathname === '/note/capture'` branch there rendering
  `CaptureView` inside the same provider. Routing stays hash-based
  (`web/src/router.ts` never sees path routes).
- Credential reuse is free: `NoteGraphQLClient.initialize()` already consumes
  `?code=` and stores the bearer per origin; `hasCredential()` reports
  registration; `appStore` exposes `auth`
  (`'unknown' | 'authenticated' | 'unauthenticated'`) and ChatbookView's
  gating pattern is `<Show when={auth !== 'unauthenticated'}
  fallback={<LoginView />}>` — reuse `LoginView` as the unregistered surface.
- The POST is plain HTTP, not GraphQL: add a `NoteGraphQLClient` method (for
  example `captureNote(text, title?)`) using `this.environment.request(
  '/note/capture', …)` with the bearer header the way `streamHeaders()`
  builds it, parsing the C6 bodies (201 `{noteId, notebookId, noteNumber}`;
  error `{error}` for 400/401/503/500).
- Test layout: `web/package.json` runs `bun test src && vitest run` — put
  pure-logic tests beside the module as `*.test.ts` (bun) and use vitest
  integration files only if DOM behavior needs pinning, following
  `ChatbookView.integration.tsx`.

### TASK-008: Web entity header on TagPane

**Parallelizable**: Yes (with TASK-006/007)

**Completion Criteria**:

- [ ] Tag mode header shows canonical note (excerpt + open link) or promote control; *create description note* flow per E3; co-occurring tag chips navigate via the return stack
- [ ] Vitest coverage for bound/unbound states and chip navigation

**Implementation notes (session-7 fact-finding, verified on disk):**

- The server GraphQL surface is DONE and accepted (TASK-005):
  `GraphQLContractProjector.swift` declares
  `promoteTagNote(input: PromoteTagNoteInput!)` /
  `unpromoteTagNote(input: UnpromoteTagNoteInput!)` and `tagDetail` carries
  `canonicalNote` + `coOccurringTags` with root-field `coOccurringTagLimit`.
- Web client work: extend the `TagDetail` interface in
  `web/src/notes/types.ts` (currently tag/tagClass/noteCount/notebookCount/
  memoNotebookId) with `canonicalNote` and `coOccurringTags`; extend the
  `tagDetail` selection in `web/src/notes/client.ts:286` to match; add
  `promoteTagNote` / `unpromoteTagNote` client methods following the
  `ensureTagMemoNotebook` mutation pattern.
- `TagPane.tsx` already loads `TagDetail` via `app.client.tagDetail(tagId)`
  and refreshes on `catalogRevision`; the entity header renders from that
  same load. *Create description note* composes three existing client
  calls: `ensureTagMemoNotebook(tagId)` → `createNote(notebookId,
  bodyMarkdown)` → `promoteTagNote`.
- Land after TASK-007 and take a fresh read of
  `web/src/state/appStore.tsx` before editing it (shared path).

### TASK-009: Docs and verification sweep

**Parallelizable**: No

**Completion Criteria**:

- [ ] `kaiba-note.md` HTTP API section lists `/note/capture` with the amended
      C6 status set (201/400/401/405/503/500)
- [ ] Full verification suite (below) green; results recorded in the progress
      log with exit statuses. The prior run's
      `TASK-000/attempt-1/swift-test-full.log` is truncated at the OOM kill
      and is NOT a completed run; the full suite must re-run to completion.
      Known pre-kill failure to re-check:
      `AgentGatewayCLIInvokerLifecycleTests.testProductionZombieDescendantWaitsForDisappearanceWithoutSIGKILL`
      (file untouched by this branch) — if it fails again, prove it
      pre-existing with the identical filter on a clean checkout of `bab58cd`
      and record both results
- [ ] (F-000-7 was closed by the resumed-run design step: the design doc now
      names `KaibaStaticSPAHTTPRouter.response(for:)`; verify no other doc
      references the nonexistent `KaibaNoteFileHTTPRouterChain`)

## Verification

Run from the repository root unless noted; record exact commands, exit
statuses and result counts in the progress log. Every Swift command goes
through the arm64 login shell (see Applicable prior knowledge):

- Once: `arch -arm64 /bin/zsh -lc 'mise run anydoc:native'`
- Iterate: `arch -arm64 /bin/zsh -lc 'export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig; swift test --filter <QuickMemo|NoteCaptureRoute|TagEntity|NoteStoreSchema|NoteGraphQLSchemaInventory>'`
- Final gate: `arch -arm64 /bin/zsh -lc 'export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig; swift build && swift test'`
  — zero failures, or each failure proven pre-existing by the same filter on
  a clean checkout of branch point `bab58cd`, both results recorded
- In `web/` (bun via mise): `tsc --noEmit`, `bun test src`, `bun run lint`, `bun run build`
- `arch -arm64 /bin/zsh -lc 'mise run lint'` (swiftlint) after Swift edits
- Smoke (no physical phone available to the run): `kaiba serve` locally,
  then curl-level `POST /note/capture` (bearer and unauthenticated) and
  `GET /note/capture` asserting the C6 bodies and the SPA bootstrap; promote
  a note on a tag and verify CLI `kaiba tag <name>` agrees with GraphQL
  `tagDetail`. The phone-browser walk-through remains a post-merge manual
  step for the operator.

## Progress Log

- 2026-09-21: Plan created together with
  `design-docs/specs/note-capture-and-entity-pages.md`. **No code was
  written in the planning run** — planning-only by contract. This repository
  keeps no plan index file (`impl-plans/README.md` registers plans by
  placement in `impl-plans/active/`), so no index row exists to update.
- 2026-09-21: Planning-run evidence that no `Sources/` or `Tests/` path is
  touched — `git diff --stat main..HEAD` at planning completion: (empty; the
  branch tip equals main, and the only additions are the two untracked
  documents `design-docs/specs/note-capture-and-entity-pages.md` and
  `impl-plans/active/note-capture-and-entity-pages.md`, confirmed by
  `git status --porcelain`). The commit closing the planning run carries
  exactly those two files; this line is to be re-verified against
  `git diff --stat main..HEAD` after that commit.
- 2026-09-21 (resumed run): Post-commit re-verification. The planning commit
  is `2ae17f8` and `git diff --stat main..HEAD` reads exactly:

  ```
   design-docs/specs/note-capture-and-entity-pages.md | 289 +++++++++++++++++++++
   impl-plans/active/note-capture-and-entity-pages.md | 185 +++++++++++++
   ...ote-capture-entity-pages-20260921-dispatch.json | 168 ++++++++++++
   3 files changed, 642 insertions(+)
  ```

  No `Sources/` or `Tests/` path appears in the branch diff; the third file
  is the dispatch manifest for the future implementation run. Note for that
  run: the working tree additionally holds *uncommitted* TASK-001-shaped
  drafts (`Sources/AppCore/NoteStoreSchema.swift`,
  `Tests/AppCoreTests/NoteStoreSchemaTests.swift`, untracked
  `Tests/AppCoreTests/NoteStoreSchemaCanonicalTests.swift`). They are
  consistent with design decisions E1 and C3 but are outside the planning
  run's scope: they are deliberately left uncommitted and unreverted as a
  head start for TASK-001, and no planning-run commit may include them.
  (Historical note: in the implementation worktree those drafts arrived
  committed inside `ba7ef12`; the tree there is clean.)
- 2026-09-21 (implementation run, analysis + design step): Recorded git
  context — worktree
  `/Users/taco/gits/tacogips/kaiba-worktrees/note-capture-entity-pages`,
  branch `feat/note-capture-and-entity-pages`, originalHead `83a4be5`,
  merge-base with main `bab58cd`, sole delta vs main = `ba7ef12`
  (24 files, +3209/−14, never built/tested/reviewed). `origin` carries only
  `main`; the feature branch is created by the first push. Coverage map: the
  commit contains candidate TASK-001..006 material with tests; TASK-007,
  TASK-008 and TASK-009 are entirely absent (zero `web/src` changes). Plan
  revised accordingly: TASK-000 review gate added, arm64/anydoc verification
  commands recorded, baseline-comparison protocol added.
- 2026-09-21 (implementation run, design step): **Accepted delta ratified.**
  `ba7ef12` amended design decision E1 with the undo-snapshot rule
  (`captureNoteSnapshot` records `canonicalTagIds`; `restoreNoteSnapshot`
  re-binds only still-unbound tags, preserving E2 last-promote-wins) and the
  unfiltered `idx_tags_canonical_note` index. Design review verified the
  implementation matches the text (`NoteService+ActionHistory.swift:285`
  snapshot query, `:416-425` unbound-only restore; `NoteStoreSchema.swift:527`
  column, `:535` index) and ratified the delta as part of the accepted
  design. The design doc Status section records the same delta.
- 2026-09-21 (resumed run, after an external OOM killed the implementation
  run): TASK-000 had completed before the kill — build gate passed (anydoc
  exit 0; `swift build` exit 0 "Build complete! (67.25s)"; targeted filter
  `QuickMemo|NoteCaptureRoute|TagEntity|NoteStoreSchema|NoteGraphQLSchemaInventory`
  = 76 tests, 0 failures; swiftlint 3 pre-existing violations, none in
  touched files), all 24 `ba7ef12` files carry verdicts (20 KEEP, 4 CORRECT,
  0 REMOVE — nothing deleted; full table in
  `tmp/note-capture-entity-pages-20260921-opus3/TASK-000/progress.md`), the
  405-shadowing question and the E1 ratification were both confirmed, and
  findings F-000-1..8 were routed. TASK-000 checkboxes checked on that
  evidence. The full-suite log from that attempt is truncated at the kill
  and does not count as a run (see TASK-009).
- 2026-09-21 (resumed run, design step): **Accepted deltas ratified**,
  closing the TASK-000 findings that demanded decisions — recorded in the
  design doc Status block and amended inline in C3/C4/C6/E6:
  - C3: per-write-principal singleton (`owner_user_id` + `library_id`, the
    insert's own bindings); closes F-000-2 by giving every account its own
    Quick Memos notebook instead of a store-wide first-owner-wins lookup.
  - C6: adds the generic 500 for service errors on route-validated requests
    (invariant violations are store defects, not 400s — closes F-000-3);
    removes the unreachable 404 arm and its constant/test (closes F-000-1).
  - C4: the once-only `notebookCreated` publish is ratified (closes
    F-000-6).
  - E6: the root-field `coOccurringTagLimit` argument is ratified with its
    engine rationale (closes F-000-4); F-000-5's fix (thread the limit
    through `NoteService.tagDetail`) is required by TASK-005.
  - F-000-7 closed directly: the design doc now names
    `KaibaStaticSPAHTTPRouter.response(for:)`. F-000-8 upgraded to a
    required TASK-006 criterion (small, testable).
  Task criteria for TASK-002/004/005/006/007/009 were revised accordingly;
  TASK-007 now pins `web/src/views/CaptureView.tsx`, the
  `location.pathname === '/note/capture'` boot detection (hash router serves
  no path routes), and the collision guard against the pre-existing
  `NoteCapture.tsx`. Environment note: `.build/anydoc-native/` was cleaned
  after the kill, so `mise run anydoc:native` must re-run before any swift
  command despite the warm 6G `.build` cache.
- 2026-09-21 (session-7 resumed run, analysis + design step; the session-6
  implementation run was killed by the same external OOM class after its
  wave-2 integration review had ACCEPTED TASK-000..006):
  - **State on disk**: HEAD `600cd5b`, tree dirty with exactly the accepted
    wave-1/wave-2 work (10 modified files, +678/−125). All eleven SHA-256
    hashes in `integration-review-wave2/acceptance-record.json`
    (`acceptedFileHashesSha256`) re-verified byte-identical to the working
    tree this session — zero drift since the kill. Wave-2 independent
    verification had run the FULL suite on this exact tree:
    `swift build && swift test` exit 0, XCTest 894 executed / 1 skipped /
    0 failures, Swift Testing 135/135
    (`integration-review-wave2/swift-build-and-test-full.log`, ends
    `SWIFT_TEST_EXIT=0 END 2026-09-21T08:34:15Z`), `mise run lint` exit 0
    with only the 3 pre-existing violations. TASK-007/008/009 evidence dirs
    are empty; `web/` is untouched by branch and tree.
  - **Consequence**: the accepted material is NOT re-reviewed and NOT
    re-derived. Execution resumes at COMMIT-A (see "Resumed-run ordering"),
    then TASK-007 → TASK-008 → TASK-009. Dispatch manifest for this run:
    `impl-plans/active/note-capture-entity-pages-20260921-opus5-dispatch.json`
    (supersedes the opus4 manifest, which stays as history).
  - **Carried findings disposition** (wave-2 record RC-1..8): RC-1 closed by
    the opus5 dispatch; RC-2/RC-3 remain TASK-009 criteria; RC-4 standing
    rule (`.riela/` is untracked and NOT gitignored — every commit stages
    explicit paths); RC-5 CLOSED by inspection (`kaibaSPABootstrapPaths` in
    `KaibaStaticAssetResolver.swift` already rewrites `/note/capture`);
    RC-6 CLOSED by inspection (`scripts/build-anydoc-native.sh` on macOS
    resolves the SwiftPM XCFramework and creates no
    `.build/anydoc-native/host/pkgconfig`; the `PKG_CONFIG_PATH` export is
    harmless there — run `mise run anydoc:native` once anyway, it is cheap);
    RC-7/RC-8 DEFERRED as cosmetic (recorded under "Resumed-run ordering";
    closing them would reopen accepted files for zero behavior change).
  - **Web fact-finding recorded** into TASK-007/TASK-008 implementation
    notes: `?code=` registration and per-origin bearer live in
    `NoteGraphQLClient.initialize()`/`hasCredential()`; `App.tsx` renders
    `ChatbookView` unconditionally today (capture branch goes there);
    `LoginView` is the existing unregistered surface; web `TagDetail` type
    and `client.tagDetail` selection need the F2 fields;
    `client.createNote`/`ensureTagMemoNotebook` already exist for the E3
    flow; web tests run `bun test src && vitest run`.
  - Team KB recall for `note-capture-entity-pages` again returned zero
    entries (kb-recall-prior, session-7).
