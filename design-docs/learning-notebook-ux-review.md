# Learning notebook UX review

Kaiba serves two purposes: an AI-assisted learning notebook for people and a shared knowledge source for automation such as Riela. This review prioritizes the learner's workflow. Notes and conversations must continue to use the canonical server records.

## Findings and changes

1. An empty library offered no way to begin writing. The home view now introduces the learning workflow and offers inline notebook creation. Writable document notebooks offer direct note capture, including a first-note form when empty. Both use existing GraphQL mutations.
2. Technical navigation labels obscured the purpose of the interface. The primary labels are now Library, My notebooks, Notebook, Learn, and Settings. Search choices describe the user action: Ask AI and Find text.
3. Empty discussions supplied no learning guidance. The Learn pane now offers Explain simply, Quiz me, and Connect ideas. Selecting a prompt stages editable text; it never sends automatically.
4. The discussion context was implicit. A context heading identifies the note or notebook being discussed.
5. Icon-only composer modes were hard to discover and crowded the writing space. The composer now uses a full-width writing area, visible mode labels, a labeled send/save action, and mode-specific help. Existing attachment and edit restrictions remain enforced.
6. Save failures need a recovery path. New notebook/note forms retain unsaved text and display an inline error; submissions are disabled while in progress.
7. Clicking reading text changed or cleared the AI subject. Context now changes through an explicit Study this note button, which also reveals Learn on mobile. Study whole notebook widens the context explicitly.
8. Unavailable AI search led to a technical explanation with no recovery action. Search now offers Find text instead, an error retry action, and useful empty-result guidance.
9. Navigation destroyed writing drafts and could carry unfinished discussion text into a different subject. Drafts now live in the app session, keyed by notebook, note, or tag. Discussion drafts retain staged attachments and the memo-only choice; sending state survives pane remounts. Completing a send clears only the submitted subject's draft. New-note and notebook creation avoid redirecting a learner who has navigated away. Drafts are deliberately session-only, with a reminder to save before closing the app; they are not shared settings or saved knowledge.
10. Reading utilities competed with studying and overflowed horizontally on phones. Access, page navigation, and export are grouped under Notebook tools; position and study-context controls remain visible. The toolbar wraps at mobile widths.
11. Search results lost their return path, and mobile navigation could leave the destination behind the Learn pane. Results now preserve a Back route and route changes reveal the notebook. Route updates remove obsolete fields and clone initial defaults, preventing stale notebook scope and shared-state mutation.
12. Quick-search keyboard focus escaped the modal, and Escape only worked in its input. The dialog now contains Tab navigation, handles Escape throughout, and restores focus on dismissal. Settings and Search also provide the main-content landmark used by the skip link.
13. Learners could create notes but only request AI edits afterward. A direct Markdown editor now saves to the same note, retains failed drafts, observes access changes, and checks the latest source text before updating. Detected changes require reviewing the current version instead of silently overwriting it. This preflight check is not an atomic concurrency guarantee: the existing server update contract is still last-write-wins.

## Verification and remaining audit

The web and Tauri checks pass. Regression coverage exercises notebook creation, failed-save recovery, navigation to the saved note, and prompt staging. Transport coverage verifies canonical mutation inputs and rejected saves. A live smoke check against the existing local server binary in `/tmp/kaiba-learning-ux.IE8M0e` verified notebook creation, note saving/reloading, and catalog visibility using the actual web GraphQL client. AI calls were disabled in that isolated store.

Additional regression coverage verifies restored writing drafts after tab changes, isolated discussion drafts, pane-reopen restoration, and completion of an old send without clearing another subject's writing.

## Completion audit, 2026-09-07

| Requirement | Current evidence | Status |
| --- | --- | --- |
| Review from a learner's perspective | Thirteen concrete findings above, covering starting, writing, reading, discussion, retrieval, navigation, and recovery | Implemented |
| Make the learning flow usable | Actual-component tests cover creation, save recovery, draft restoration, learning prompts, subject changes, manual editing, and search-return navigation | Passed |
| AI-assisted learning | Prompt staging and existing chat request/stream/memo integration checks; prompts do not send automatically | Passed mechanically |
| Keep one canonical knowledge store | Actual web client creates, reloads, lists, and edits notes through an isolated running Kaiba server; editing preserves the note ID | Passed |
| Web validation | `mise run web:check`: 159 unit tests, 38 integration tests, TypeScript, ESLint, production build | Passed |
| Native-client validation | `mise run tauri:check` and `git diff --check` | Passed |
| Desktop and phone visual/interaction quality | No connected browser returned by discovery in three consecutive goal turns | Blocked |

The remaining completion gate is rendered desktop and phone inspection, including long titles, expanded Notebook tools, the editor, the learning composer, keyboard focus visibility, and scrolling with a software keyboard. Source review and DOM tests cannot prove those visual properties. The goal must not be marked complete without this evidence. The isolated smoke server was stopped after testing; its test-only store remains at `/tmp/kaiba-learning-ux.IE8M0e`. No production data was used, no AI network calls were made, and no release or commit was created.
