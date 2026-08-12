# AI Agent Runtime, Import, UI Scope, and Auto-Tagging Decisions

Recorded 2026-08-12 while planning the AI/import/chatbook feature set.

## Question 1

The agent runtime (session/prompt handling, spawning claude/codex CLIs)
has not been extracted from riela into agent-gateway yet; agent-gateway
currently holds only provider-routing configuration. How should kaiba
get agent capability now?

## Answer 1

Wait for agent-gateway. Build UI, PDF import, and persistence first;
wire agent chat and tagging only after the runtime is extracted into
agent-gateway. Kaiba defines the `AgentInvoking` seam and configuration
now; the adapter and end-to-end verification are a blocked final phase.

Superseded and resolved 2026-08-12: agent-gateway now exposes the ACP stdio
runtime, and Kaiba integrates it through
`Sources/AppCore/AgentGatewayCLIInvoker.swift`. Agent chat, tagging, model
discovery, streaming, and end-to-end verification are no longer blocked by
runtime extraction. Codex and Cursor remain vendor choices behind this shared
adapter rather than direct provider-specific integrations.

## Question 2

How should kaiba integrate anydoc-swift for PDF/document-to-markdown?

## Answer 2

Make tacogips/anydoc-swift usable (mechanism left to implementation).
Superseded 2026-08-12: use `AnydocKit` directly as a pinned SwiftPM library.
The resolved dependency builds its Rust FFI during Kaiba build preparation;
there is no installed CLI or `import.anydocPath` runtime setting.

## Question 3

Where does the chatbook-style three-pane screen live in the web viewer?

## Answer 3

Full redesign: the three-pane layout replaces the main screen entirely.

## Question 4

When should AI tag auto-extraction run?

## Answer 4

Automatic extraction toggles via configuration (`ai.autoTag.auto`
on/off), and manual triggering must also exist (CLI and UI).
