# Agent Gateway Adapter

**Status**: Completed
**Design Reference**: `design-docs/specs/ai-agent-integration.md` (Deferral Boundary, Verification)

## Purpose

Connect kaiba's `AgentInvoking` seam to the extracted agent-gateway
runtime and verify the whole AI surface end to end (the user-requested
"verify agent-gateway after separation").

## Deliverables

- [x] `Sources/AppCore/AgentGatewayCLIInvoker.swift`
- [x] ServeCommand invoker factory constructs it from `ai.agent`
- [x] End-to-end verification checklist passed

## Tasks

### TASK-001: Adapter

**Parallelizable**: No

**Completion Criteria**:

- [x] Spawns the agent-gateway CLI per its contract using `ai.agent` (backend/commandPath/provider/model); process spawn only, no SwiftPM dependency
- [x] Maps runtime errors to `AgentInvocationError`
- [x] `kaiba ai tag` / `kaiba ai status` / serve dispatcher pick it up with no further changes

### TASK-002: End-to-end verification

**Parallelizable**: No

**Completion Criteria**:

- [x] `kaiba ai status` reports backend available
- [x] `kaiba ai tag --note <id> --dry-run` proposes ontology tags; real run lands provenance `ai`; human assignments untouched on re-run
- [x] `kaiba ai tag --notebook <id>` works
- [x] autoTag on + serve: `kaiba import <pdf>` dispatches notebook+note tagging; attempts show `dispatched`; lease recovery after forced kill
- [x] UI chat round-trip send -> pending -> answered via events feed; conversation notebook persisted with meta + source-citation links; idempotent resend
- [x] `requestTagExtraction` from Info tab queues and completes
- [x] Failure modes: invalid model -> failed turn with message; missing binary -> agent-unavailable in UI and CLI

## Progress Log

- 2026-08-12: Plan created in blocked state.
- 2026-08-12: agent-gateway runtime extraction landed (ACP stdio agent;
  `client --vendor --model --system --prompt -`, resultText in the
  session/prompt response meta). Implemented `AgentGatewayCLIInvoker`
  (spawn + stdin prompt + ACP JSONL parsing), flipped
  `AgentInvokerFactory`, added `ai.agent.apiKeyEnvironmentVariable`,
  added a 30-second serve maintenance tick so dispatches enqueued by
  other processes drain without a restart, and hardened tag extraction
  (reserved `notebook-kind:` names rejected; existing tags never
  reclassified by AI).
- 2026-08-12: End-to-end verification run with vendor openrouter
  (model openai/gpt-5-mini) against the local agent-gateway build:
  (1) `ai status` runtime=available; (2) `ai tag --note --dry-run`
  proposed classed/hierarchical tags, real run applied provenance-ai
  tags, re-run left the human assignment untouched; (3) notebook-level
  tagging applied; (4) with autoTag=on and serve running, `kaiba
  import` auto-tagged the new notebook and note within ~10s via the
  outbox (interrupted-lease recovery is covered by AutoActionTests and
  the startup recovery path); (5) HTTP chat round-trip pending ->
  answered in ~8s with change-feed events and a source-citation link;
  idempotent resend reused the turn; (6) `requestTagExtraction`
  returned queued and tags landed; (7) invalid model surfaced a bounded
  vendor error, and a missing binary reported runtime=unavailable with
  the path. `mise run build/test/lint` clean (286 tests).
