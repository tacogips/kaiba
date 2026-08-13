# Tag Detail Pane

**Status**: Completed
**Design Reference**: `design-docs/specs/tag-detail-pane.md` (T1-T9)

## Purpose

Make tags navigable subjects: underline attached tag names inside note
bodies, open a cross-notebook tag pane (Memo | History | Links) from tag
terms and chips, support repeated Back navigation after following
occurrence links, and register mouse-selected text as a tag.

## Deliverables

- [x] `NoteService` tag detail surface: `tagDetail`, `listTagComments`,
      `ensureTagMemoNotebook` (+ `tag-memo` kind tag, tree exclusion)
- [x] GraphQL: `tagDetail` / `tagComments` queries,
      `ensureTagMemoNotebook` mutation, contract + DTO + executor wiring
- [x] Web: `notes/tagMatch.ts` matcher + underlined terms in the reader
- [x] Web: tag-mode right pane (Memo via tag memo notebook, History,
      Links occurrences) addressed by `?tag=<id>`
- [x] Web: return stack with visible Back control
- [x] Web: drag-select-to-tag popover using `applyNoteTags`
- [x] Tests per design Verification section; docs updated

## Tasks

### TASK-001: Backend tag detail service

**Parallelizable**: Yes (with TASK-003)

**Completion Criteria**:

- [x] `tagDetail(tagId:)` returns tag, class, parent, note/notebook
      counts (descendant-expanded), memo notebook id or nil
- [x] `listTagComments(tagId:limit:offset:)` aggregates note + notebook
      comments across notebooks, descendant-expanded, newest first,
      excluding `tag-memo` notebooks; attributed with subject titles
- [x] `ensureTagMemoNotebook(tagId:)` idempotently finds/creates the
      `tag-memo` notebook (kind tag + subject tag, title `Tag: <name>`)
- [x] `tag-memo` notebooks excluded from the notebook tree/listing the
      same way `agent-conversation` notebooks are
- [x] Unit tests in `Tests/AppCoreTests`; `swiftlint` clean

### TASK-002: GraphQL surface

**Parallelizable**: No (needs TASK-001)

**Completion Criteria**:

- [x] Contract string, DTOs, service wrappers, executor dispatch, and
      field whitelists cover `tagDetail`, `tagComments`,
      `ensureTagMemoNotebook`
- [x] Pagination validated against existing bounds (limit 0…200)
- [x] Executor tests pass; `swift build` + targeted `swift test` green

### TASK-003: Web tag matching + underlines

**Parallelizable**: Yes (with TASK-001)

**Completion Criteria**:

- [x] `notes/tagMatch.ts`: matcher from note ∪ notebook tags, folder and
      system kind tags excluded, >= 2 chars, ASCII-case-insensitive,
      longest-first; splits only `text` inline segments; unit tests
- [x] `Markdown.tsx` renders matched terms as focusable underlined
      elements with `data-tag-id`; reader click handling opens tag mode
      without toggling note selection

### TASK-004: Web tag-mode right pane

**Parallelizable**: No (needs TASK-002, TASK-003)

**Completion Criteria**:

- [x] `?tag=<id>` route param parse/format round-trips (router tests)
- [x] Right pane tag mode: header (name, class, counts, close) + tabs
      Memo | History | Links
- [x] Memo tab drives the existing notebook-subject memo/chat surface
      against the tag memo notebook; first submit ensures the notebook
- [x] History tab pages `tagComments`; Links tab groups cross-notebook
      occurrences by notebook; tag chips in Info/Tags tabs open tag mode
- [x] Client queries + types added following `queryValue` pattern

### TASK-005: Return stack + drag-select-to-tag

**Parallelizable**: No (needs TASK-004)

**Completion Criteria**:

- [x] Store-owned LIFO (cap 50) pushed by right-pane navigation; Back
      control visible when non-empty; repeated pops restore route,
      selection, and `?tag=`; reducer tests
- [x] Drag-select popover registers trimmed selection (reject empty,
      > 64 chars, cross-note) via `applyNoteTags`; underlines refresh
- [x] `bun run typecheck && bun run test && bun run lint && bun run
      build` green

## Progress Log

- 2026-08-13: Plan created alongside `tag-detail-pane.md` spec.
- 2026-08-13: TASK-001/002 done. `NoteService+TagDetail.swift` adds
  `tagDetail`, `listTagComments`, `ensureTagMemoNotebook`,
  `tagContextMarkdown`, `tagMemoSubjectTagId`; agent chat grounds
  tag-memo notebook subjects on tagged notes. GraphQL: `tagDetail` /
  `tagComments` queries + `ensureTagMemoNotebook` mutation wired through
  contract, DTOs, service, executor, projector. Tests:
  `NoteTagDetailTests`, `NoteGraphQLTagDetailTests`; full
  `swift test` green, `swiftlint` clean (one pre-existing warning).
  Deviation from the initial draft: the memo notebook binds via
  `kaibaTagMemo.subjectTagId` meta JSON (no subject-tag assignment, no
  tree exclusion — matches conversation-notebook behavior); spec updated.
- 2026-08-13: TASK-003/004/005 done. Web: `notes/tagMatch.ts` (+tests),
  underlined tag terms in `Markdown.tsx`/`ReaderPane.tsx`, `?tag=` route
  param (+router tests), tag-mode right pane (`components/TagPane.tsx`:
  Memo via lazily ensured memo notebook, History paging `tagComments`,
  Links via cross-notebook `notes(tagFilter)`), clickable tag chips,
  `state/returnStack.ts` (+tests) with reader Back control, drag-select
  popover registering human tags. `tsc --noEmit`, `bun test src`,
  vitest, eslint, `bun run build` all green. HTTP smoke against
  `kaiba serve`: tagDetail counts, idempotent ensureTagMemoNotebook,
  attributed tagComments verified.
- 2026-08-13: Self-review pass. Backend: `applyTags`/`removeTag` now
  publish a `note-tags` change event (silent when a removal deletes
  nothing; spec T10, observer test added), so underlines, the tag pane,
  and the tag catalog live-update across clients — verified end-to-end
  against `/note/events`. Web: `openTagPane` unfolds a collapsed right
  pane; `TagPane` resets detail/memo-notebook state when the tag
  switches mid-flight (a stale memo notebook could otherwise receive the
  new tag's submissions); drag-to-tag now refreshes the catalog so new
  tags label correctly at once; the selection popover clamps to the
  viewport and dismisses on scroll. Full `swift test` (371 green),
  `swiftlint` (pre-existing warning only), tsc/bun test/vitest/eslint/
  build all green.
