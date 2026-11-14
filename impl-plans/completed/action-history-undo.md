# Action History and Undo/Redo

**Status**: Completed (2026-08-21)
**Design Reference**: `design-docs/specs/action-history-undo.md`

## Purpose

Give kaiba a durable per-actor action history with undo/redo, stored as
delta-only log entries so the log stays small (U4), recorded atomically
with each mutation (U2).

## Deliverables

- [x] `note_action_log` table in the idempotent schema list (U1)
- [x] `NoteActionHistory.swift`: entry model, action kinds, splice patch
- [x] `NoteService+ActionHistory.swift`: recorder, pruning, queries
- [x] `NoteService+UndoRedo.swift`: undo/redo application
- [x] Recording calls in the in-scope `NoteService` mutations (U10)
- [x] GraphQL: `actionHistory`, `undoState`, `undoAction`, `redoAction`
- [x] CLI: `kaiba history`, `kaiba undo`, `kaiba redo`
- [x] Tests per the spec's Verification section

## Tasks

### TASK-001: Storage, model, and splice patch

**Parallelizable**: Yes

**Completion Criteria**:

- [x] DDL + indexes appended to `schemaStatements`
- [x] `NoteActionLogEntry`, `NoteActionKind`, splice patch make/apply
- [x] Splice patch unit tests (multi-byte safe, guarded)

### TASK-002: Recorder and mutation call sites

**Parallelizable**: No (after TASK-001)

**Completion Criteria**:

- [x] `recordAction(_:in:)` inserts + prunes (U9)
- [x] All U10 call sites record inside their transactions
- [x] `updateNoteBody` gains `provenance:`; agent edit passes `.ai`

### TASK-003: Undo/redo application

**Parallelizable**: No (after TASK-002)

**Completion Criteria**:

- [x] Target/redo-target queries (U3, U7), one-hop resolution (U8)
- [x] Bidirectional apply per kind with conflict guards (U5, U6)
- [x] Deferred snapshots captured/cleared (U4, U9)
- [x] Change events published after commit (U13)

### TASK-004: GraphQL and CLI surfaces

**Parallelizable**: No (after TASK-003)

**Completion Criteria**:

- [x] Executor cases + contract projector + supported-fields registry
- [x] CLI subcommands wired

### TASK-005: Tests and validation

**Parallelizable**: No (after TASK-004)

**Completion Criteria**:

- [x] `NoteActionHistoryTests` green
- [x] GraphQL contract tests green
- [x] `mise run build`, `mise run test`, `mise run lint` green

## Progress Log

- 2026-08-21: Plan created; spec accepted.
- 2026-08-21: All tasks implemented; 501 tests green, lint clean of new violations, CLI smoke test (add/edit/tag/history/undo/redo/delete-undo) passed. Plan moved to completed.
