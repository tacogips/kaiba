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

## Question 2

How should kaiba integrate anydoc-swift for PDF/document-to-markdown?

## Answer 2

Make tacogips/anydoc-swift usable (mechanism left to implementation).
Chosen mechanism: spawn the installed `anydoc-swift` CLI with `--json`;
binary path configurable via `import.anydocPath`. No SwiftPM
dependency.

## Question 3

Where does the chatbook-style three-pane screen live in the web viewer?

## Answer 3

Full redesign: the three-pane layout replaces the main screen entirely.

## Question 4

When should AI tag auto-extraction run?

## Answer 4

Automatic extraction toggles via configuration (`ai.autoTag.auto`
on/off), and manual triggering must also exist (CLI and UI).
