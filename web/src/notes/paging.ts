import type { Notebook, NoteListSort } from './types'
import { notebookPageLimit } from './client'

export { notebookPageLimit } from './client'
export const notebookPageCap = 1_000

export interface NotebookPageClient {
  notebooks(
    offset: number,
    sort: NoteListSort,
    tagFilterIdGroups: string[][],
    limit?: number,
    created?: { createdAfter?: string; createdBefore?: string },
  ): Promise<Notebook[]>
}

export class NotebookPartialLoadError extends Error {
  readonly notebooks: Notebook[]

  constructor(message: string, notebooks: Notebook[]) {
    super(message)
    this.name = 'NotebookPartialLoadError'
    this.notebooks = [...notebooks]
  }
}

export async function loadNotebookPages(
  client: NotebookPageClient,
  sort: NoteListSort,
  tagFilterIdGroups: string[][],
  isCurrent: () => boolean,
  onPage: (notebooks: Notebook[], hasMore: boolean) => void,
  pageCap = notebookPageCap,
  created: { createdAfter?: string; createdBefore?: string } = {},
): Promise<Notebook[] | undefined> {
  const result: Notebook[] = []
  const seen = new Set<string>()
  let offset = 0
  const effectivePageCap = Math.min(Math.max(pageCap, 1), notebookPageCap)
  for (let pageIndex = 0; pageIndex < effectivePageCap; pageIndex += 1) {
    const page = await client.notebooks(offset, sort, tagFilterIdGroups, notebookPageLimit, created)
    if (!isCurrent()) return undefined
    let added = 0
    for (const notebook of page) {
      if (seen.has(notebook.notebookId)) continue
      seen.add(notebook.notebookId)
      result.push(notebook)
      added += 1
    }
    const hasMore = page.length === notebookPageLimit
    onPage([...result], hasMore)
    if (!hasMore) return result
    if (added === 0) {
      throw new NotebookPartialLoadError(
        'Notebook paging stopped because a full page made no forward progress.',
        result,
      )
    }
    offset += page.length
  }
  throw new NotebookPartialLoadError(
    `Notebook paging stopped after ${effectivePageCap} pages.`,
    result,
  )
}
