import type { Note } from './types'

// Pure note-text helpers shared by the reader, the tree and the search popup.
// DOM-free so they can be unit tested directly.

export const searchPageSize = 20

/** Preview of the title the server derives while composing: the first ATX
 * heading, else the first non-empty line, capped like `NoteTitleDerivation`. */
export function derivedNoteTitle(bodyMarkdown: string, defaultTitle = 'Untitled'): string {
  const lines = bodyMarkdown.split('\n').slice(0, 40)
  const heading = lines
    .map((line) => /^ {0,3}(#{1,6})\s+(.*)$/.exec(line)?.[2])
    .find((value) => value !== undefined && value.trim().length > 0)
  const candidate = heading ?? lines.find((line) => line.trim().length > 0 && !/^ {4,}/.test(line))
  const title = candidate?.replace(/\s+#+\s*$/, '').trim()
  if (!title) return defaultTitle
  return title.length > 120 ? `${title.slice(0, 120)}…` : title
}

export function noteDisplayTitle(note: Note): string {
  const title = note.title?.trim()
  return title && title.length > 0 ? title : `Note ${note.noteNumber}`
}

/** Slugged markdown-export filename mirroring `rielaNoteExportFilename`:
 * lowercase, non-alphanumerics collapsed to dashes, first 8 dash segments. */
export function noteExportFilename(title: string, fallback = 'note'): string {
  const slugged = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .split('-')
    .filter((segment) => segment.length > 0)
    .slice(0, 8)
    .join('-')
  return `${slugged.length > 0 ? slugged : fallback}.md`
}
