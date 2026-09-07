# Memo chat notebooks

The requested end state treats each memo as a notebook that can be opened and
continued as an agent chat. A memo attached to a chat turn inherits conversation
history through that turn; a memo attached to an ordinary note includes the note
and basic notebook identity. No application-defined prompt budget is required.

Implemented:

- Persistent branch snapshots including inherited attachments, without context caps.
- Ordinary note context includes notebook title/ID and note ID/number.
- Memo conversation entries can open their backing notebook.
- Conversation notebooks render a chat composer that continues that notebook.
- Chat timelines load all pages.
- Plain memo saves atomically create a backing notebook without agent dispatch.
- Older comments gain a reusable backing notebook on first open.
- Pending import comments cannot publish derived context before finalization.
- Notebook type is explicit in the core model, GraphQL, and web/Swift clients.

Completion evidence:

- `AgentChatBranchTests`: stable and nested branch snapshots, parent attachments,
  complete large context, notebook page history, and provider history beyond 100 turns.
- `MemoNotebookTests`: atomic save/reuse, legacy comments, no unsolicited dispatch,
  initial source context including empty chats, library enforcement, and follow-up
  provider requests containing inherited conversation plus memo text.
- `AgentChatGraphQLTests`: open/reopen mutation and explicit notebook type projection.
- `MemoTab.integration.tsx`: expanded draft preservation, branch navigation,
  direct notebook sends, and memo-only saves targeting that notebook and remaining visible.
- `ChatbookView.integration.tsx`: actual reader/store/router path from source memo
  to notebook chat, missing-catalog metadata loading, send, and return to source.
- `NotebookIngestConcurrencyTests`: unfinished imports retain their visibility boundary.
- Verification: full Swift suite under the Xcode toolchain, final targeted chat
  tests, `mise run web:check`, `mise run tauri:check`, and `mise run lint`.

The full design and data behavior are recorded in
`design-docs/specs/agent-chat-branches.md`. No deployment or commit is included.
