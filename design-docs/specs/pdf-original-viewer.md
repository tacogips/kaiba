# PDF reading, searchable text, and page context

Accepted user decisions, 2026-10-24. Supersedes the PDF raster storage and image-only viewer parts of `design-document-page-images.md`.

## Storage and text extraction

PDF uploads retain one original PDF attachment. Every physical page has a source note with its page number, searchable-text state, and a reference to the original PDF. Raster images are temporary OCR input, removed after recognition, rather than saved page attachments. Native PDF text extraction does not require rasterizing a page. Deferred OCR renders the requested page from the retained PDF and removes the temporary image afterward.

The default extraction policy prefers usable embedded PDF text and falls back to OCR for pages without it. Settings can instead choose OCR only. The import form can override that default per document; the CLI accepts `--text-mode prefer-pdf-text` or `--text-mode ocr-only`. The existing OCR page limit controls recognition work, including importing without OCR with a limit of `0`.

Extracted text is plain search text, stored in `document_pages.text` (see [note-store-schema-v25.md](note-store-schema-v25.md)). OCR preserves wording, reading order, line breaks, and paragraph breaks without adding Markdown syntax or summaries. Page bodies remain separate from searchable text; annotations use page memos. Document titles default to the uploaded filename and can be renamed.

## Reader and navigation

PDF.js displays the authenticated original PDF. A single compact header contains the editable document title, current-page tags, Original/OCR/Translated version controls, a translation action, and a searchable-state icon. The OCR view displays the available extracted text, including native PDF text, as plain text. The status icon exposes its explanation through its accessible label and tooltip; activating it opens Analysis. Analysis includes document/file information and the action to make a page searchable.

The footer contains previous/next navigation, the current physical page and total, a page-number jump, and PDF zoom controls when viewing the original. Clicking either page edge turns pages according to document binding. Left/Right keys follow binding; Ctrl+U selects the previous physical page and Ctrl+D the next. Editing fields and open dialogs keep these shortcuts from changing pages.

All page selections use the central reader navigation. Back restores previous reader selections, including jumps from tag results, linked notes, numbered jumps, page controls, and keyboard navigation. The in-memory return stack retains at most 500 entries; repeated selections of the same destination do not add a redundant step.

## Page tags and ontology

Clicking a page-tag name opens a popup listing tagged notes/pages across notebooks, with pagination and navigation to the selected source note. Editing and removing a tag use separate icon controls. Adding a tag supports free input and catalog-defined types, including Date, Name, and Place. Date tags offer a calendar input. Existing tags retain their catalog class, and suggestions display qualified hierarchy information. Renaming a page assignment does not rename a shared tag globally.

## Translation and discussion

The header translation action accepts a target language and scope: current page, an inclusive page range, or the whole document. A request creates a translation job; each source page gets one Translated version per language (`note_translations`), replaced when the page text changes and marked outdated until then. Original, extracted text (OCR), and translated text are the three selectable versions; available translations are selected by language. Translation content is rendered as plain text. Moving to a page without a matching selected translation must not leave the previous page's translation visible.

The selected source page remains the context for memos, AI discussion, tags, and navigation even while viewing its translation. AI discussion lives in the bottom composer, scoped to the current page or, with no page selected, the notebook. The right pane contains Tags, Analysis, Links, and AI. AI lists saved conversations; selecting one continues it in the footer without moving away from the document. The footer also offers saved-conversation access, a larger reading panel, and a return to the current page discussion with its draft intact. PDF AI context uses extracted text and neighboring/search results; temporary raster images are not attached to conversations.

Standalone image uploads and existing raster-page notebooks remain readable. This change does not automatically delete old attachments; normal storage garbage collection handles unreferenced files.

## Verification boundary

Automated checks exercise storage, extraction policy, reader rendering, translation version selection, source-page context, tags, and navigation history. Real AI provider execution is a separate integration check; unit/integration fixtures do not establish that a live provider has translated a document successfully.

## Link destinations and previews

The Links pane separates saved links from suggestions based on shared tags or similar text. Saved links show whether the current page links to the destination or the destination links to the current page, together with the stored relation type and provenance. Every entry identifies its destination notebook/document and physical page or note number.

Hovering or focusing an entry opens a preview without changing the current selection. The preview icon also supports explicit opening on touch. PDF previews show extracted text and offer an original-page rendering; ordinary notes show their content. Opening the destination uses the central navigation history, so Jump back restores the source. Preview requests are lazy, and pending responses are discarded when closed.
