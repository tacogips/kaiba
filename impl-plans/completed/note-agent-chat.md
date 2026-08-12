# Note Agent Chat Persistence and GraphQL

**Status**: Completed
**Design Reference**: `design-docs/specs/ai-agent-integration.md` (AI6-AI8)

## Purpose

Persist note-level agent conversations as agent-conversation notebooks
with a pending-turn lifecycle, and expose the chat and tagging surfaces
over GraphQL for the web UI.

## Deliverables

- [x] `Sources/AppCore/NoteService+AgentChat.swift`
- [x] GraphQL: `noteConversations`, `sendAgentChatMessage`, `requestTagExtraction` (a separate `noteTagDetails` proved unnecessary: `Note.tags` already carries structured `NoteTagAssignment` with class, parent, and provenance, and `Note.metaJSON` is already exposed)
- [x] Executor and service tests

## Tasks

### TASK-001: Chat lifecycle service

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `startConversation` (kind tag, `kaibaChat` meta, source-citation links)
- [x] `appendPendingChatTurn` / `completeChatTurn` / `failChatTurn` (status pending/answered/failed; `originatingActionId` on completion writes)
- [x] `listConversations(subjectNoteId:)` via `json_extract`
- [x] Idempotent sends replay, not duplicate

### TASK-002: Query `noteConversations`

**Parallelizable**: Yes (with TASK-003..005)

**Completion Criteria**:

- [x] Full AppGraphQL touchpoint checklist: SDL, projector line, `supportedNoteGraphQLFields`, `noteGraphQLQueryFields`, root switch, `noteGraphQLRootSelectionTypes`, `noteGraphQLSelectionFields`, service, DTO, inputs, diagnostics, contract-test field list — all in the same change
- [x] Limits rejected outside 0...200

### TASK-003: Mutation `sendAgentChatMessage`

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Creates conversation on first message; returns `{conversationNotebookId, turnNoteId, agentStatus}`
- [x] `agentStatus` = `agent-unavailable` when no dispatcher installed; user turn still persisted
- [x] Same touchpoint checklist as TASK-002

### TASK-004: Mutation `requestTagExtraction`

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Exactly one of noteId/notebookId; returns `queued` or `agent-unavailable`
- [x] Same touchpoint checklist

### TASK-005: Query `noteTagDetails` (+ meta JSON exposure check)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Verified instead of implemented: the GraphQL `Note` type already
  exposes `metaJSON` and structured `tags` (`NoteTagAssignment` with
  `tag { classId, parentTagId }` and `provenance`), so no new field was
  needed; the Info tab reads `note.tags` directly

### TASK-006: Tests

**Parallelizable**: No

**Completion Criteria**:

- [x] Lifecycle tests; per-field executor tests (success, validation rejection, diagnostics)
- [x] `mise run build/test/lint` clean

## Progress Log

- 2026-08-12: Plan created.
- 2026-08-12: Implemented, tested (swift build/test/lint clean), and completed.
