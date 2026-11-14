/** Typed wrappers around the store's opaque string ids.
 *
 * The GraphQL wire format carries every id as a plain string, and the reader
 * threads a great many of them around — note, notebook, tag, class, file,
 * comment. Spelling them all `string` meant a notebook id could be passed
 * where a note id was expected and the mistake only showed up as an empty
 * pane. Each kind is its own branded type here, so the compiler rejects the
 * mixup while the runtime value stays the same string.
 *
 * The brand is one-way: a `NoteId` is still a `string` (usable in template
 * literals, URLs, and object keys), but a bare `string` is not a `NoteId`.
 * Turning raw text into an id is therefore always explicit — the constructors
 * below mark the boundaries where untyped text (a route parameter, a JSON
 * payload, a DOM attribute) enters the typed world.
 */

declare const idBrand: unique symbol

type Branded<Name extends string> = string & { readonly [idBrand]: Name }

/** Identifies a note page. */
export type NoteId = Branded<'NoteId'>
/** Identifies a notebook. */
export type NotebookId = Branded<'NotebookId'>
/** Identifies a library (design-docs/specs/library.md). */
export type LibraryId = Branded<'LibraryId'>
/** Identifies an account (design-docs/specs/multi-user.md). */
export type UserId = Branded<'UserId'>
/** Identifies a tag. */
export type TagId = Branded<'TagId'>
/** Identifies a tag class, the namespace a tag belongs to. */
export type TagClassId = Branded<'TagClassId'>
/** Identifies a stored file blob. */
export type FileId = Branded<'FileId'>
/** Identifies a memo attached to a note or notebook. */
export type CommentId = Branded<'CommentId'>

export const noteId = (raw: string): NoteId => raw as NoteId
export const notebookId = (raw: string): NotebookId => raw as NotebookId
export const libraryId = (raw: string): LibraryId => raw as LibraryId
export const userId = (raw: string): UserId => raw as UserId
export const tagId = (raw: string): TagId => raw as TagId
export const tagClassId = (raw: string): TagClassId => raw as TagClassId
export const fileId = (raw: string): FileId => raw as FileId
export const commentId = (raw: string): CommentId => raw as CommentId

/** Builds an id from caller-supplied text, rejecting blank input. Boundaries
 * that read ids out of routes or form fields use this so an empty value never
 * becomes a lookup key. */
export const parseId = <Id extends string>(
  make: (raw: string) => Id,
  raw: string | null | undefined
): Id | null => {
  const trimmed = (raw ?? '').trim()
  return trimmed === '' ? null : make(trimmed)
}

/** The tag classes every store is seeded with; the reader singles out folder
 * tags, which shape the notebook tree. */
export const FOLDER_TAG_CLASS = tagClassId('folder')
export const DOCUMENT_KIND_TAG_CLASS = tagClassId('document-kind')
