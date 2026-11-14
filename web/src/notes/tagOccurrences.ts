import type { Note } from './types'

export const tagOccurrencesPageLimit = 200

/** Loaders receive the page limit explicitly so the "was this page full"
 * check below can never drift from the size actually requested. */
export type TagOccurrencePageLoader = (tagName: string, offset: number, limit: number) => Promise<Note[]>

/** Synchronous state transition used by the tag Links controller before it
 * starts a request. Changing tag identity must remove all old link targets. */
export function transitionTagOccurrences(
  previousTagId: string,
  nextTagId: string,
  current: Note[],
): Note[] {
  return previousTagId === nextTagId ? current : []
}

/** Loads the complete offset-paginated tag occurrence feed. Returning
 * `undefined` means the tag selection changed while a request was pending. */
export async function loadTagOccurrences(
  tagName: string,
  loadPage: TagOccurrencePageLoader,
  isCurrent: () => boolean,
): Promise<Note[] | undefined> {
  const occurrences: Note[] = []
  const seenNoteIds = new Set<string>()
  let offset = 0

  while (isCurrent()) {
    const page = await loadPage(tagName, offset, tagOccurrencesPageLimit)
    if (!isCurrent()) return undefined

    const newNotes = page.filter((note) => !seenNoteIds.has(note.noteId))
    if (page.length === tagOccurrencesPageLimit && newNotes.length === 0) {
      throw new Error('tag occurrence pagination did not advance')
    }
    for (const note of newNotes) seenNoteIds.add(note.noteId)
    occurrences.push(...newNotes)

    if (page.length < tagOccurrencesPageLimit) return occurrences
    const nextOffset = offset + page.length
    if (nextOffset <= offset) throw new Error('tag occurrence pagination did not advance')
    offset = nextOffset
  }
  return undefined
}
