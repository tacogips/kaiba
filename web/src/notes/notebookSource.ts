import { parseNotebookDraft } from './notebookDraft'

/** Escape literal boundary lines in stored notes before joining the notebook. */
export function notebookSource(bodies: readonly string[]): string {
  return bodies.map((body) => {
    const boundaries = parseNotebookDraft(body).notes.slice(0, -1).map((note) => note.endOffset)
    let source = body
    for (const offset of boundaries.reverse()) {
      const marker = source.indexOf('<><>', offset)
      source = `${source.slice(0, marker)}\\${source.slice(marker)}`
    }
    return source
  }).join('\n\n<><>\n\n')
}
