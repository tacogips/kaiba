# Reader layout and navigation, 2026-10-25

- Markdown notebooks use notebook-wide Preview and Writing controls. Switching
  keeps one continuous Markdown buffer, including its caret and undo history.
  Preview renders unsaved buffer text. Notes use
  compact margins and simple separators, without cards or per-note page labels.
- The composer continues to split notes at standalone `<><>` outside code;
  `\<><>` stays literal. Its outline uses titles without numeric badges.
- `i` outside text fields starts Writing at the current note in INSERT mode.
  There is one Vim indicator at the bottom left. J/K move logical lines in
  Writing; Shift+V and Ctrl+V select lines and rectangles. Ctrl+W followed by
  `h/l/j/k/w` focuses library/details/AI/reader/next pane. Settings can change these
  bindings and reject ambiguous sequences.
- Ctrl+D/U turns physical PDF pages and scrolls Markdown reader viewports.
  J/K scrolls Preview. Editing fields, dialogs, and other panes keep
  their own keyboard behavior. Reader header focus does not block navigation.
- Preview shows a note title only when its title is nonblank. It has no per-note
  Ask AI buttons. The AI panel selects notebook/current note/note number/range
  context, including unsaved writer text or searchable PDF text.
- Header tabs never scroll horizontally. A measured ellipsis button expands
  tabs that do not fit; the selected tab remains visible.
- Imported notebooks have file icons; independent read-only notebooks retain locks.
- Left and right dividers resize their panes. The AI panel's top edge resizes its
  height; double-click resets it. Its top-right controls provide fullscreen,
  exit fullscreen, and collapse. Escape exits fullscreen and restores the docked
  height. The collapsed launcher remains at the bottom right.
- Expanded trees fetch notes in batches of 200 near the bottom of the library
  viewport, and render only the revealed batches even when the writer has
  already fetched the whole notebook. Existing rows remain mounted during fetching and catalog refreshes.
  Concurrent requests for the same next batch are shared, and completion stops
  further requests. A Load more control provides a manual alternative.

Markdown creation and save support up to 2,000 notes. Unchanged sections retain
their IDs, tags, and memos through middle insertions, deletions, and moves; edited
sections between unchanged anchors retain their order. Ambiguous fully rewritten
or duplicate sections use ordered matching.

## Validation

Native Brave review on the isolated current-checkout server at port 8790 verified
both side dividers, the bottom divider, fullscreen, Escape, top-right collapse,
notebook-wide Writing/Preview, file icons, compact note separators, and PDF
Ctrl+D/U from a focused header control. No document text was edited in this review.
The separate compatibility server at port 8788 was not changed.

Integration coverage includes unsaved draft previews, physical-key shortcuts,
editable-field isolation, fullscreen height restoration, and a 1,000-note tree:
200-row batches, duplicate request suppression, retained row identity and scroll
position, terminal pagination, and catalog/note refresh stability.

Final browser review also verified global `i` from the details pane, one INSERT
indicator, line/rectangle highlights, hidden tab selection, AI range fields,
and the combined model picker with case-insensitive substring `PUS` matching
Claude Opus. The selected default is GPT-6.1 Sol; no AI request was sent during
this review. Models and credential availability are documented in
[cross-vendor model selection](cross-vendor-model-picker-20261025.md).

Final web checks: 1,317 Bun tests, 222 Vitest integration tests, TypeScript, ESLint,
and production build pass. Tauri formatting passes. Focused Swift verification
includes stable-ID reconciliation, 1,001-note creation and 1,002-note save, model
routing, subscription policy, and credential isolation; the executable was rebuilt
and the isolated port-8790 server restarted with current model defaults.

The complete `mise run test` suite also passes: 1,239 XCTest cases (10 opt-in
skips) and 149 Swift Testing cases, with no failures. The updated credential
routing expectation explicitly verifies migration from Claude Opus 5 to 5.5.
