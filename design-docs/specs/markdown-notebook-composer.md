> Current separator decision (2026-10-24): standalone `<><>` creates a note;
> `\<><>` is literal text using Markdown escaping. Former hyphen-marker rules
> below describe the earlier implementation and are superseded. Existing stored
> notes are unchanged.

# Markdown notebook composer

New Notebook opens a writing workspace with a notes outline, a continuous Markdown
source editor, Write/Preview controls, and a compact status bar. The preview renders
each draft note separately. Outline entries select the corresponding source section
or preview, and the add button inserts a note separator.

The first nonblank line of the first note names the notebook. Markdown heading
markers are omitted from the title; later headings never replace it. A standalone
angle-bracket marker containing three or more hyphens (`<--->`, `<---->`,
`<----->`, and longer forms) begins the next note. Hyphen-only rules such as `---`, `----`,
and `-----` retain their ordinary Markdown meaning. Separators inside fenced code, block quotes, and
indented code remain content. Empty notes are retained. Boundary blank lines are
removed while Markdown content and internal line endings are preserved.

Typing nonblank text starts automatic saving after three quiet seconds. There
is no Create notebook button. The upper right shows Unsaved changes, Saving,
Saved, or a retry error, beside a notebook menu containing Delete notebook.
Typing remains enabled during a save. The app owns the save queue so navigating
away cannot discard it. Sign-out invalidates in-flight responses.

Initial creation uses the atomic `ingestNotebookPages` mutation with one writable
page per draft note. Subsequent saves use `saveNotebookDraft`, which reconciles
ordered notes and the notebook title in one transaction. Existing note IDs are
preserved; new sections create notes and removed sections delete trailing notes.
A repeated snapshot does not append duplicate notes. Each page receives its own database note ID and note number.
The submitted source and initial-creation idempotency key remain fixed across a
failed-save retry while later typing waits for the next save.
There is no additional database schema or Markdown-document blob.

PDF and image import stays in the Create and import menu popup. Markdown notebook
creation and adding Markdown notes remain independent of document import.

## Validation, 2026-10-24

- Parser tests cover title derivation, separators, fenced code, CRLF, blank notes,
  source offsets, and unfinished fences. Client tests check the separate-page
  mutation payload and rejection of an empty first-note title.
- Editor integration checks cover preview, outline counts, adding a note, and
  preserving the exact source and request key for retries.
- Native browser review covered empty, populated Write, and Preview layouts. A
  three-note draft was saved and reloaded. GraphQL and direct SQLite reads verified
  distinct ordered records with exact Markdown bodies. SQLite and Meilisearch
  both returned the saved third note.
- The runtime check used the existing schema-24 isolated preview store and its
  compatibility server, preserving the existing PDF test library. Primary-source
  checks passed: 192 Bun tests, 154 Vitest tests, TypeScript, production build, and
  `mise run tauri:check`.
- Runtime evidence: `tmp/pdf-validation-20261024/notebook-composer-check.json`.
  The temporary validation notebook was removed after verification.

## Automatic-save follow-up

- Web checks: 192 Bun tests, 158 Vitest tests, TypeScript, lint, and production
  build passed. Tauri formatting passed. SwiftLint reported only the two existing
  large-tuple warnings.
- Focused Swift tests cover separate note records, stable IDs on replay, removing
  sections, search updates, read-only and ownership rejection, empty sections,
  and the published GraphQL mutation. All 30 draft and ingestion tests pass;
  empty initial draft sections opt into the new `allowEmptyPages` input flag.
- Native browser validation created a notebook from one character, retained the
  focused editable source, updated its title and three notes in place, displayed
  Saved, and exposed Delete notebook from the upper-right menu. Direct SQLite
  reads verified the same notebook ID, separate records, an empty final note, and
  a literal separator inside fenced code.
- Evidence: `tmp/pdf-validation-20261024/notebook-autosave-check.json`.

## Workspace action hierarchy

The workspace has one menu containing New notebook and document import. It has
no separate duplicate New notebook toolbar button, and Add note is absent from
this global menu. Add note belongs to the notebook writer outline or the current
notebook's note controls. The Add a note keyboard shortcut targets that same
context, including the active automatically saved writer.

The folder toolbar button toggles the library on desktop and switches between
library and reader on compact screens. Its expanded state and tooltip explain
that behavior. Tags and Links live in the right pane rather than duplicate
workspace buttons. A generic details-pane toggle on the right side of the header
keeps the pane accessible on compact screens; its tabs and keyboard shortcuts
select the specific detail views.

## Separator decision, 2026-10-24

The agreed boundary is an angle-bracket marker containing three or more hyphens
on its own line: `<--->`, `<---->`, `<----->`, and longer forms. This replaces the old
four-hyphen boundary and the unimplemented HTML-comment proposal. `<--->` is
the canonical form inserted by Add note. The parser,
Add note button, empty-state help, and footer now use this marker. Hyphen-only
rules retain their Markdown meaning; markers inside fenced/indented code,
quoted lines, and inline text remain content. Existing database note records
are unchanged.

## Continuous editing identity reconciliation, 2026-10-25

Notebook saves preserve unchanged note IDs when a standalone `<><>` inserts or
removes a section in the middle. Exact body matches form an ordered common
subsequence, with duplicate ties favoring their existing positions. Additional
unchanged moved sections retain their IDs too. Edited sections retain IDs in
order within the gaps between these anchors: a split keeps the original ID on
its first part, and a merge keeps the first surviving section's ID. Consequently,
following unchanged notes retain their tags, memos, links, and translations.
Completely rewritten or identical duplicate sections cannot carry unambiguous
identity through plain text alone; matching within those changed gaps is ordered.

The transaction snapshots removed notes before renumbering survivors, then uses
temporary distinct positions to avoid unique-index conflicts and publishes the
final consecutive order. Replaying the same snapshot retains the same IDs. The
exact-match working table is bounded; exceptionally large existing notebooks use
exact-body matching without that table rather than allocating unbounded memory.

Markdown creation and saves accept up to 2,000 sections, including empty sections.
The 400 KiB per-section limit and the independent 2 MiB HTTP request limit remain.
PDF import retains its separate physical-page bound. Native Preview matches
unchanged section bodies to metadata while an unsaved split is pending, so a new
section does not temporarily display the following note's tags or title.
