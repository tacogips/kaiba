# Backlinks and explicit notebook separators

## Notebook note boundaries

A standalone `<><>` line starts the next note. Add note inserts that same
marker. Write `\<><>` to keep a literal marker, using Markdown backslash escaping.
The backslash stays in stored Markdown and is hidden when prose is rendered.
Inline markers, quoted markers, and markers in fenced or indented code remain
content. Code spans and fenced code retain backslashes literally.

The former `<--->` / `<---->` / `<----->` forms are now ordinary text. Existing
stored note records remain separate and unchanged. Plain Markdown rules and
heading underlines retain their existing meaning. The outline, preview, and
atomic save consume the same parsed draft.

## Backlinks

The right-pane Links tab is replaced by Backlinks. Its persisted internal tab key
remains `links`, preserving existing pane preferences. The keyboard shortcut is
labelled Backlinks. Selecting a notebook alone asks the user to select a note or
page; the old notebook-wide mixed-direction link aggregate is removed.

Backlinks uses the existing scoped `noteLinks` API and accepts only edges whose
destination is the current note. Outgoing-only edges and self-links are excluded.
Multiple incoming edge kinds from one source produce one source entry with all
its link types and provenance. Inferred tag/topic/text relationships stay in the
other relationship tabs.

Each entry reuses the destination preview and navigation control: source title,
notebook and note/page number, link meaning, mouse-over/focus/tap preview, open,
and central jump-back history. There is no graph-neighbor result truncation.
Source notes load in pages of 50 with at most eight simultaneous reads. Missing
sources report a retryable partial-read error rather than silently appearing as
an empty list. Catalog and notebook revisions refresh the incoming links.

## Verification, 2026-10-24

- Parser tests cover three-, four-, five-, and longer-hyphen forms; plain rules;
  inline, quoted and code content; CRLF; and empty notes.
- Transport and editor tests cover different marker lengths and canonical Add
  note insertion.
- Backlink integration tests cover incoming direction, exclusion of outgoing
  and self links, duplicate source grouping, type/provenance, preview, navigation,
  a 55-source paginated list, and the unselected-note state.
- Native browser verification saved four notes from the three separator forms,
  then added an empty fifth note with the button. Exact SQLite bodies preserved
  Markdown rules and a fenced marker.
- Four explicit test links produced two referring sources in Backlinks; the
  outgoing-only destination was absent. Native source preview, jump, reload,
  and jump-back were verified.
- `mise run web:check` passed 195 Bun tests, 164 Vitest tests, TypeScript,
  ESLint, and production build. `mise run tauri:check` passed.
- Runtime evidence: `tmp/pdf-validation-20261024/separators-backlinks-runtime-check.json`.
  Only the temporary validation notebooks and their notes/links were removed.

## Separator change, accepted 2026-10-24

The user replaced the former angle/hyphen marker with `<><>` and requested
Markdown-style backslash escaping. Current parser and editor tests cover exact
standalone matching, escaped literal text, fenced/indented/quoted/inline content,
CRLF, empty notes, and canonical Add note insertion. Earlier verification above
for hyphen-marker variants is historical; the new rule requires its own UI rerun.
