import type { NoteGraphQLClient } from './client'
import type { Note, Notebook } from './types'
import { documentPageMetadata } from './documentPages'
import { fileToChatAttachment } from './memoComposer'
import { parseNotebookDraft } from './notebookDraft'

export type AIContextSelection = { mode: 'current' | 'note' | 'range' | 'notebook'; start: string; end: string }
export async function aiNoteContext(client: NoteGraphQLClient, notebook: Notebook, current: Note | undefined, selection: AIContextSelection, draft?: { source: string; noteNumber: number }) {
  const attachment = async (sections: string[]) => [await fileToChatAttachment(new File([
    `Selected reference context from notebook: ${notebook.title}\nUse these selected notes as the reference for this question.\n\n${sections.join('\n\n<><>\n\n')}`,
  ], 'selected-note-context.txt', { type: 'text/plain' }))]
  if (draft) {
    const parts = parseNotebookDraft(draft.source).notes
    const start = selection.mode === 'notebook' ? 1 : selection.mode === 'current' ? draft.noteNumber : Number(selection.start)
    const end = selection.mode === 'notebook' ? parts.length : selection.mode === 'range' ? Number(selection.end) : start
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || end > parts.length) throw new Error('Enter a valid note number or range for this notebook.')
    return attachment(parts.slice(start - 1, end).map((part, index) => `Note ${start + index}: ${part.title}\n${part.bodyMarkdown}`))
  }
  if (selection.mode === 'notebook') return []
  let notes: Note[]
  if (selection.mode === 'current') {
    if (!current || current.notebookId !== notebook.notebookId) throw new Error('Select a note in this notebook before using current-note context.')
    notes = [current]
  } else {
    const start = Number(selection.start)
    const end = selection.mode === 'note' ? start : Number(selection.end)
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 1 || end < start || (notebook.noteCount != null && end > notebook.noteCount)) {
      throw new Error('Enter a valid note number or range for this notebook.')
    }
    notes = []
    let offset = start - 1
    while (notes.length < end - start + 1) {
      const batch = await client.notes(notebook.notebookId, offset)
      if (!batch.length) throw new Error('The selected note range could not be loaded.')
      notes.push(...batch.filter((note) => note.noteNumber >= start && note.noteNumber <= end))
      offset += batch.length
      if (batch.at(-1)!.noteNumber >= end) break
    }
    if (notes.length !== end - start + 1) throw new Error('The selected note range could not be loaded.')
  }
  const sections = await Promise.all(notes.map(async (note) => {
    const text = documentPageMetadata(note) ? (await client.documentPageText(note.noteId)).text : note.bodyMarkdown
    return `Note ${note.noteNumber}: ${note.title ?? ''}\n${text}`
  }))
  return attachment(sections)
}
