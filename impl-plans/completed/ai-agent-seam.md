# AI Agent Seam and Auto-Tag Wiring

**Status**: Completed
**Design Reference**: `design-docs/specs/ai-agent-integration.md`

## Purpose

Give kaiba the AI plumbing that works without riela: `ai` configuration,
the `AgentInvoking` protocol, ontology tag extraction, the auto-action
dispatcher, serve wiring with action reconciliation, and the `kaiba ai`
CLI. Actual model invocation is deferred to the agent-gateway adapter
plan.

## Deliverables

- [x] `KaibaConfiguration` `ai` section (agent backend, autoTag on/off)
- [x] `Sources/AppCore/AgentInvoking.swift`
- [x] `Sources/AppCore/AITagExtraction.swift`
- [x] `Sources/AppCore/KaibaAutoActionDispatcher.swift`
- [x] ServeCommand invoker factory + dispatcher install + action reconciliation
- [x] `seedAutoActions` notebook-created tagging row + id constants
- [x] `Sources/AppCore/CommandAI.swift` + `kaiba ai` branch in `main.swift`
- [x] Tests

## Tasks

### TASK-001: Spec (ai-agent-integration.md)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Spec accepted (AI1-AI8, deferral boundary, Phase D checklist)

### TASK-002: Configuration structs

**Parallelizable**: Yes

**Completion Criteria**:

- [x] `ai.agent {backend, commandPath?, provider?, model?}` and `ai.autoTag.auto` decode-if-present; default off; encode round-trip
- [x] No secret values in config

### TASK-003: AgentInvoking protocol

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Request (purpose, systemPrompt, turns, contextMarkdown, provider/model), result, `AgentInvocationError` incl. `.notConfigured`

### TASK-004: Tag extraction service

**Parallelizable**: No (after TASK-003)

**Completion Criteria**:

- [x] Prompt with ontology snapshot and strict JSON contract
- [x] Reply validation: reject folder/unknown classes; hierarchy-aware resolve-or-create; provenance `ai`; note and notebook level
- [x] Skips agent-conversation notebooks

### TASK-005: Dispatcher

**Parallelizable**: No (after TASK-004)

**Completion Criteria**:

- [x] Routes workflow ids `note-auto-tagging` / `note-agent-reply`; unknown id fails
- [x] Errors surface as `.failed` and ride existing lease/retry

### TASK-006: Serve wiring and reconciliation

**Parallelizable**: No (after TASK-002, TASK-005)

**Completion Criteria**:

- [x] Invoker factory (returns nil until adapter exists; warns when configured)
- [x] With invoker: dispatcher installed, `recoverAndRetryAutoActionDispatches()` at startup, actions reconciled per `autoTag.auto`
- [x] Without invoker: AI actions force-disabled; no outbox buildup

### TASK-007: `kaiba ai` CLI

**Parallelizable**: No (after TASK-004)

**Completion Criteria**:

- [x] `kaiba ai tag --note|--notebook <id> [--dry-run]`; clean "not configured" exit 1 until adapter exists
- [x] `kaiba ai status`

### TASK-008: Tests

**Parallelizable**: No

**Completion Criteria**:

- [x] Config decode; dispatcher routing with stub invoker; tag-reply validation incl. human-tag precedence; reconciliation logic
- [x] `mise run build/test/lint` clean

## Progress Log

- 2026-08-12: Plan created; spec accepted.
- 2026-08-12: Implemented, tested (swift build/test/lint clean), and completed.
