# Editor Vim Mode

## Status

Accepted (2026-10-24). Initial implementation.

## Summary

- **The Markdown editors use Vim keybindings by default.** This covers the
  notebook composer (`NewNotebookEditor`), the note edit form (`NoteEditor`),
  note capture (`NoteCapture`), and the Fast Notes quick capture. They open in
  normal mode. Chat and agent composers, short form fields, and the
  phone-oriented `/capture` page keep native textarea behavior.
- **Settings > Editor turns it off** (`vimMode: false` in the `web` app
  setting). An absent value means on, so existing stores get Vim without a
  migration.
- **Keybindings are user-defined** through a keymap JSON document edited in
  Settings > Editor and stored as `vimKeymap` in the same `web` setting. The
  keymap therefore follows the store across devices, like the font scale.
- The engine is ported from vactr (`editor/src/code/vim`, tacogips/vactr). The
  keymap schema, the presets (`Default`, `mise-darwin`), which-key hints and
  hop jumps all behave as they do there.

## Architecture

- `web/src/editor/vim/`: the vactr engine, DOM-free (`test/purity.test.ts`).
  It edits a CodeMirror `EditorState` (`@codemirror/state`,
  `@codemirror/commands` for history). It never imports `@codemirror/view`.
- `web/src/editor/textareaVim.ts`: the host. A shadow `EditorState` mirrors
  the textarea:
  - Vim edits go to the shadow state, are written to the textarea, and are
    announced with a synthetic `input` event, so Solid `onInput` drafts and
    autosave stay in step.
  - Trusted native input in insert mode is diffed back into the shadow state
    with the user events that `.` and macros record. The diff's prefix is
    capped at the caret, so typing into a run of equal characters is
    recorded where it happened.
  - Programmatic value changes (Solid re-renders, untrusted `input` events)
    are adopted as external edits outside the undo history.
  - Normal and visual modes refuse native text input (`beforeinput`). An IME
    composition started in normal mode is discarded at `compositionend`.
  - In normal mode the textarea still selects the character under the
    cursor, but the native caret and selection are transparent; a measured
    overlay (`.vim-block-cursor`) draws the block, so empty lines and the end
    of the text also show a full cell. The overlay only shows while the
    editor is focused.
  - Command chords, and Control chords that are neither built-in Vim chords
    nor mapped, pass through to the app, so workspace shortcuts keep working.
    Tab keeps moving focus.
- `web/src/editor/textareaGeometry.ts`: measures textarea positions through a
  hidden mirror element and DOM Ranges. It drives `scrollCaret`, the viewport
  that `H`/`M`/`L` and `Ctrl-d`/`Ctrl-u` use, `isVisible`, and hop label
  placement. Soft-wrapped lines measure correctly.
- `web/src/editor/VimTextarea.tsx`: `createVimTextarea({ save, close })`
  returns a `ref` for the textarea and a `Status` component (mode badge,
  pending keys, `:`/`/`/`?` prompt, messages, hints, hop labels). It attaches
  and detaches live as the setting or the keymap changes.

## Kaiba-specific changes to the vactr engine

- Actions: `kaiba.save` and `kaiba.close` (modes n, x, i) replace vactr's
  live-coding actions (`vactr.evaluate*`, `vactr.hush`, `vactr.format`,
  `vactr.diagnostic.*`, `vactr.completion`). `hop.*` actions are unchanged.
- Ex commands: `:w`/`:w!`/`:write` save, `:q`/`:q!`/`:quit` close, and
  `:wq`/`:wq!`/`:x` do both. Save defaults to submitting the textarea's form,
  which runs each editor's own save. Close defaults to blurring the editor;
  the note edit and capture forms close their drafts instead. Unknown command
  names no longer resolve through `Object.prototype`.
- Limits: the keymap is at most 40,960 UTF-8 bytes and 1,000 entries, so the
  whole `web` setting stays under the server's 64KB setting cap.
- The `mise-darwin` preset drops the diagnostic and evaluate mappings (listed
  under `unsupported`). It adds `<leader>w` (save) and `<leader>q` (close).

## Keymap document

```json
{
  "version": 1,
  "leader": "<Space>",
  "timeoutlen": 1000,
  "maps": {
    "i": [{ "lhs": "jk", "rhs": "<Esc>", "desc": "Leave insert mode" }],
    "n": [{ "lhs": "<leader>w", "action": "kaiba.save", "desc": "Save" }]
  },
  "hints": { "enabled": true, "delayMs": 200, "triggers": { "n": ["<Space>"] } },
  "hop": { "enabled": true, "keys": "fdjhklsagqwertyuiopzxcvbnm" }
}
```

Modes are `n`, `i`, `x` (`v` is an alias), `o` and `c` (command-line keys).
Without a stored keymap, the editor uses the `Default` preset: no mappings
or hop, and which-key hints for `g`, `z` and `m` (normal) and `g` (visual)
shown with no delay. Applying a keymap that has entry errors
skips those entries and keeps the rest. A keymap that cannot be parsed is not
applied.

## Known limits

- Insert-mode `Cmd/Ctrl-Z` uses the shadow history; the browser's native undo
  stack is bypassed.
- Registers are per editor instance; yanks also go to the system clipboard.
- On touch devices without a hardware keyboard, the mode badge toggles insert
  mode.

## Writing view and workspace keys, 2026-10-25

- Writing shows line numbers in a gutter (`editor/LineNumberGutter.tsx`).
  Only the logical lines in view are measured, through the same mirror
  geometry, so a soft-wrapped line keeps its number on its first row. The
  caret's line is bold.
- Workspace bindings (`notes/workspaceVimKeys.ts`) are configurable in
  Settings > Editor and checked for overlapping sequences:

  | Keys | Action | Where |
  | --- | --- | --- |
  | `i` | Write at the current note (insert mode) | outside text fields |
  | `<C-w>h/l/j/k/w` | Focus library / details / AI / reader / next pane | everywhere |
  | `<Space>w` | Toggle Writing / Preview (Writing opens in normal mode) | outside text fields and in a Vim editor's normal mode |
  | `<Space>a` | Open / close the AI panel | same |
  | `<Space>e`, `<Space>d` | Toggle library, details | same |
  | `<Space>f` | Quick switcher | same |
  | `gp` | Go to page: prompts for a number | outside text fields |
  | `gg`, `G` | First, last page | outside text fields |

  A count typed before `gp`, `gg` or `G` outside text fields jumps to that
  page (`12gg`). Page commands reach the document reader (physical pages)
  and the Markdown reader (notes). In Writing they place the caret at the
  note's first line; inside the editor `g` keeps its Vim meaning.
- In a Vim editor the workspace only takes `<Space>` in normal mode with no
  pending Vim command (`data-vim-pending`), and only if the editor keymap maps
  nothing starting with `<Space>`. A keymap such as `mise-darwin`, whose
  leader is `<Space>`, keeps those keys in the editor.
- A pending prefix lists its next keys at the bottom right, Helix style, with
  the typed prefix (and count) as the heading and each entry shown as its full
  sequence. The editor's own which-key hints use the same panel. There is no
  prefix timeout; `Esc`, a click, or a non-matching key cancels it.
