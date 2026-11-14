# Note/page separator decision, 2026-10-24

Accepted by the user: replace the former `<--->` / `<---->` / `<----->` note
boundary with `<><>`.

- A standalone unescaped `<><>` line outside code starts a new note.
- `\<><>` remains in the same note and displays as literal `<><>` in prose.
- Backslash escaping follows Markdown punctuation escaping; code spans and code
  fences preserve backslashes literally.
- Inline, quoted, and indented markers do not split notes.
- Former hyphen markers and `======` are ordinary notebook content. Existing
  database notes remain separate without migration.

The equals-sign proposal was rejected because it overlaps Markdown Setext
heading syntax. `<><>` is visually distinct and has no standard Markdown role.
