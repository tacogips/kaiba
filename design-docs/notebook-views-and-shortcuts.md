# Notebook views and keyboard shortcuts

The library header has tree and timeline icons. Tree is the default for existing installations. The selected mode persists with pane layout. Timeline shows the same notebooks as the tree (agent conversations remain in chat), newest updated first. Ordering compares timestamp instants, including timezone offsets, and uses notebook ID to break ties. Catalog refreshes reorder the list automatically. Selecting an entry opens its notebook and returns mobile users to the reader.

The shared web UI handles keyboard events in both Tauri and the browser. Command is used on macOS and Control elsewhere. Native system-wide shortcuts are unnecessary: commands apply while the app window has focus. Browser-reserved combinations may be handled by the browser itself.

| Command | Shortcut |
| --- | --- |
| New notebook / resume notebook draft | Command/Control N |
| Add a note | Command/Control Shift N |
| Save current writing | Command/Control S |
| Show notebooks | Command/Control Shift 1 |
| Toggle tree / timeline and show library | Command/Control Shift T |
| Quick switcher | Command/Control P |
| Open contextual agent chat | Command/Control Shift A |
| Open and focus Ask AI | Command/Control J |
| Start a new contextual chat | Command/Control Shift J |
| Tags / links / history | Command/Control Shift 2 / 3 / 4 |
| Settings | Command/Control , |
| Toggle library / details pane | Command/Control B / Shift B |
| Keyboard reference | Command/Control / |
| Send chat / insert newline | Enter / Shift Enter |

The keyboard icon opens the reference generated from the command registry. Existing unmodified `/`, `[`, and `]` shortcuts remain available outside editors. Modified commands work from editors and preserve drafts through the existing draft store. IME composition, repeated key events, prevented events, and open dialogs suppress workspace commands. Save uses the enabled submit button in the focused writing form, or the visible writing form; it never sends an agent message. Individual controls retain ordinary Tab, Shift Tab, Enter, and Space access.

Navigation commands defer pane selection and editor focus until asynchronous hash navigation has mounted the destination. This also preserves the requested mobile pane when returning from Settings, search, or a tag panel.

Validation: `mise run web:check` covers view icons, persisted mode migration, absolute timestamp ordering, catalog refresh reordering, notebook navigation, keyboard modifiers, draft retention, IME/dialog guards, and asynchronous route destinations. `mise run tauri:check` verifies the shared UI's native shell through Rust formatting, compilation, and Clippy. Tauri loads the same frontend and its default macOS menu does not reserve the workspace command combinations. A live native GUI check could not run because the computer-use service failed to start.
