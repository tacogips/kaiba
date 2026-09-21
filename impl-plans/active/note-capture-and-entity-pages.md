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

- [ ] TASK-000 review: every `ba7ef12` file verified against the design;
      keep/correct/remove log recorded in the progress log
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

### TASK-000: Review the starting material

**Parallelizable**: No (wave 0; gates every other task)

**Completion Criteria**:

- [ ] `arch -arm64 /bin/zsh -lc 'mise run anydoc:native'` then
      `arch -arm64 /bin/zsh -lc 'export PKG_CONFIG_PATH=$PWD/.build/anydoc-native/host/pkgconfig; swift build'`
      succeed (fix compile errors inside the owning task's scope first)
- [ ] Every file of `git show ba7ef12` reviewed against design decisions
      C1–C7 / E1–E8 and the C6 contract; per-file keep / correct / remove
      verdicts recorded in the progress log
- [ ] Anything the design does not call for is deleted; anything wrong is
      fixed under its owning TASK; the E1 delta ratification is confirmed
      against the actual `NoteService+ActionHistory.swift` behavior

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
- [ ] `captureQuickMemo(bodyMarkdown:title:)` routes through `createNote`, returning the created note; auto-action enqueue and change event proven by tests
- [ ] Concurrency/idempotency and duplicate-kind-tag failure tests pass

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

- [ ] `ServerContracts.route` gains `POST /note/capture` → `routeNoteCapture` implementing the C6 contract exactly (201/400/401/405/503 bodies)
- [ ] `GET /note/capture` serves the SPA bootstrap via the `/note/register` rewrite pattern
- [ ] Route tests cover every status body, authenticated and `--allow-unauthenticated` modes

### TASK-005: GraphQL surface

**Parallelizable**: Yes (with TASK-004)

**Completion Criteria**:

- [ ] `tagDetail` payload exposes `canonicalNote` and `coOccurringTags(limit)`
- [ ] `promoteTagNote` / `unpromoteTagNote` mutations return `NoteMutationPayload`; operation allow-lists updated
- [ ] Schema contract doc string (`GraphQLNoteSchemaContract.swift`) updated; executor tests pass

### TASK-006: CLI surface

**Parallelizable**: Yes (with TASK-007/008)

**Completion Criteria**:

- [ ] `kaiba tag promote --tag <name-or-id> --note <note-id>` and `kaiba tag unpromote --tag <name-or-id>` implemented in `CommandTags.swift` following `tag define` conventions
- [ ] `kaiba tag <name-or-id>` prints canonical note and top co-occurring tags
- [ ] `Command.swift` usage text updated; command tests extended

### TASK-007: Web capture page

**Parallelizable**: Yes (with TASK-006/008)

**Completion Criteria**:

- [ ] `/note/capture` SPA route renders textarea + submit; posts to `POST /note/capture` with the stored bearer credential; success shows the note id and clears; unregistered visitors are routed to registration
- [ ] Vitest coverage for submit, error body rendering, unregistered redirect

### TASK-008: Web entity header on TagPane

**Parallelizable**: Yes (with TASK-006/007)

**Completion Criteria**:

- [ ] Tag mode header shows canonical note (excerpt + open link) or promote control; *create description note* flow per E3; co-occurring tag chips navigate via the return stack
- [ ] Vitest coverage for bound/unbound states and chip navigation

### TASK-009: Docs and verification sweep

**Parallelizable**: No

**Completion Criteria**:

- [ ] `kaiba-note.md` HTTP API section lists `/note/capture`
- [ ] Full verification suite (below) green; results recorded in the progress log with exit statuses

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
