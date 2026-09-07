# Memo chat notebooks and branches

Every notebook exposes a `type`: `DOCUMENT` or `AGENT_CHAT` (`NotebookType`
in Swift and GraphQL). It is derived from the persisted notebook-kind tag,
which remains the canonical discriminator. This avoids a second writable
type field that could disagree with existing metadata. Existing notebooks
need no migration. The web reader uses this explicit type to choose its view;
the Swift client exposes the equivalent `KaibaNotebookType`.

Notes inside an agent-conversation notebook can be used as the subject of a
separate agent conversation. Creating that conversation captures the original
subject context and the parent conversation through the selected note, inclusive.
The snapshot is stored in the new notebook's `kaibaChat.branchContext` metadata.
Later parent messages or edits do not change it. Further branches inherit this
snapshot plus their own parent turns. Existing subject owner/library validation
continues to run before context is read. Ordinary note chats include the complete
note body and basic source notebook information (title/ID and note ID/number).
Edit mode continues to use the current subject body for guarded edits.

Saving a plain memo creates its backing agent-conversation notebook and a first
turn containing the memo text, in the same transaction as the comment. That
turn is marked `memoOnly` and never dispatches an agent request. The notebook's
`kaibaChat.memoCommentId` identifies its source comment; the comment remains
available for existing comment APIs, search, and source-pane presentation.
Opening a memo uses the `openMemoNotebook(commentId:)` mutation and reuses that
notebook. Older comments are materialized on first open. Comments created inside
unfinished document imports remain hidden and can only be materialized after
the source import is finalized. Source ownership and library checks apply.

Plain memo notebooks snapshot their initial source context when created. A
subsequent agent question receives that context followed by the saved memo and
the notebook's conversation history. Memo headings are never interpreted as
assistant replies.

Branch context preserves all parent turns through the branch point, including
attachment text. Kaiba imposes no byte or turn-count budget on chat context.
Note, notebook, and tag subjects are passed without truncation. Provider context
window errors are surfaced by the existing invocation error path. Attachment
upload validation remains separate from prompt assembly; accepted historical
attachments are never omitted to meet an application-defined prompt budget.

The Agent pane offers **Branch from here** on each turn, opening that turn as
the note subject. Sending the first message creates the branch; later messages
continue that branch using the existing conversation persistence. **Expand chat
view** expands the same mounted pane, retaining drafts and reply streams.
**Open as notebook** navigates to the backing notebook in the main reader,
which renders the conversation and sends directly into that notebook. Back
returns to the source. A memo-only initial turn appears once in the source pane
as a memo card and appears as user text without an empty agent reply in its
own notebook. All conversation pages are loaded for the chat timeline.

## Existing local gateway support

Kaiba's `AgentGatewayCLIInvoker` launches a locally installed `agent-gateway`
executable and consumes its ACP JSONL replies and streaming updates. Configure
`ai.agent.backend` as `agent-gateway-cli`, `provider` and `model`, and optionally
`commandPath` (otherwise the executable is resolved on PATH). This differs from
Riela's in-process gateway library, but already provides local gateway execution.
Local invocations support coding CLI vendors. HTTP-served execution uses the
existing isolated API-provider path and rejects `codex`, `claude-code`, and
`cursor`; this change does not alter that execution policy.
