# Document Page Images: decisions and open questions

Design: `design-docs/specs/design-document-page-images.md`.

## Decisions taken without a user answer (2026-10-01)

All of these can be reversed. None of them blocks implementation.

- **OCR storage**: OCR text moves to a dedicated server-internal
  `notes.search_text` column. It is not kept in `bodyMarkdown` or `metaJSON`, and
  it is not exposed through GraphQL, KaibaClient or the CLI.
- **Migration**: the migration moves each existing page body to `search_text`
  as a whole, with no transformation. Any text a user typed into a page note
  before the upgrade becomes hidden search and RAG text. It is not deleted.
  Comments are the way to annotate pages from now on. Later OCR on such a page
  keeps the migrated text and adds the recognized text before it.
- **Page note titles**: titles stay derived from the OCR text, as before. The
  table of contents therefore keeps its labels. Only the page body is hidden.
- **Search snippets**: snippets for page notes are taken from the OCR text, so a
  search hit explains why it matched.
- **Figure extraction**: figure extraction and `import.figures` are dropped.
  Page images already show the figures. Figure files attached by earlier
  imports stay attached and are not shown.
- **Images sent to the agent**: agent chat sends only the current page image, at
  most 3,750,000 bytes. Neighbouring pages contribute OCR text only, at most
  2,000 characters each. Retrieved material is limited to six windows of at most
  1,500 characters each.
- **Vision support**: vision support is decided per provider, not per model.
  A model without vision under an image-capable provider fails the turn with the
  provider's error. Kaiba does not retry automatically.
- **openai-compatible**: credentials of this type always use the text fallback.

## Open questions

- Should notebook translation of a page-image notebook translate the hidden
  OCR text into a readable Markdown notebook? For now the translation receives
  empty bodies. This is out of scope for this change.
- Should a per-model or per-credential "send images" switch be added, for
  example to turn images on for a vision-capable `openai-compatible` endpoint?
  This is deferred until a real configuration needs it.
- Should chat optionally send adjacent page images for questions about spreads?
  This is deferred. It would raise request cost and needs a budget for more
  than one image.
