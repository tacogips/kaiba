import type { Notebook, NoteTagAssignment } from './types'
import type { TagId } from './ids'

const hiddenNotebookKinds = new Set([
  'notebook-kind:agent-conversation',
  'notebook-kind:long-term-memory',
  'notebook-kind:tag-memo',
])

/** User-facing notebooks in most-recently-written order. Internal notebooks
 * that back agent conversations, memory, and tag memos stay out of the diary. */
export function diaryNotebooks(notebooks: Notebook[], tagId?: TagId): Notebook[] {
  return notebooks
    .filter((notebook) => !notebook.tags.some((assignment) =>
      hiddenNotebookKinds.has(assignment.tag.name)))
    .filter((notebook) => !tagId || notebook.tags.some((assignment) => assignment.tag.tagId === tagId))
    .sort((left, right) => compareTimestampDescending(left.updatedAt, right.updatedAt)
      || left.notebookId.localeCompare(right.notebookId))
}

/** Category assignments shown on diary cards. System kind markers are
 * implementation details; AI, human, and ordinary system classifications are
 * useful browsing metadata and remain visible. */
export function notebookCategories(notebook: Notebook): NoteTagAssignment[] {
  return notebook.tags.filter((assignment) => !assignment.tag.name.startsWith('notebook-kind:'))
}

/** The API supplies up to 160 characters, leaving the UI to choose its compact
 * presentation. Array.from keeps composed Unicode code points intact. */
export function notebookPreview(value: string | null | undefined, limit = 80): string {
  const normalized = value?.replace(/\s+/gu, ' ').trim() ?? ''
  if (normalized.length === 0) return 'No note text yet.'
  const characters = Array.from(normalized)
  if (characters.length <= limit) return normalized
  return `${characters.slice(0, limit).join('')}…`
}

function compareTimestampDescending(left: string, right: string): number {
  const leftTime = Date.parse(left)
  const rightTime = Date.parse(right)
  if (Number.isFinite(leftTime) && Number.isFinite(rightTime)) return rightTime - leftTime
  return right.localeCompare(left)
}
