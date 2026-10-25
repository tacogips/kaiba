import { documentPageMetadata } from './documentPages'
import type { Note, Notebook } from './types'

/** Import provenance, independently of whether the notebook is writable. */
export function importedNotebookSource(notebook: Notebook, notes: Note[] = []): string | undefined {
  try {
    const source = JSON.parse(notebook.metaJSON ?? 'null')?.source
    if (typeof source?.originalFilename === 'string' && source.originalFilename.trim()
      && typeof source.format === 'string' && source.format.trim()) return source.originalFilename
  } catch { /* Legacy notebooks can still be identified by their page descriptors. */ }
  return notes.some((note) => documentPageMetadata(note)) ? notebook.title : undefined
}
