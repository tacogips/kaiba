import { onCleanup } from 'solid-js'
import { createStore } from 'solid-js/store'
import type { NoteGraphQLClient } from '../notes/client'
import type { NoteId, NotebookId } from '../notes/ids'
import type { Note } from '../notes/types'
import { documentPageMetadata } from '../notes/documentPages'

export type OCRTaskStatus = 'queued' | 'running' | 'completed' | 'failed' | 'cancelled'
export interface OCRTask {
  id: string
  noteId: NoteId
  notebookId?: NotebookId
  label: string
  pageNumber?: number
  forceOCR?: boolean
  status: OCRTaskStatus
  error?: string
  createdAt: string
  finishedAt?: string
}

/** The app owns this queue, so changing pages or opening Tasks never unmounts
 * the request. One recognition at a time respects server OCR admission limits. */
export function createOCRTasks(client: NoteGraphQLClient, onComplete: (note: Note) => void, onFailure?: (error: unknown, task: OCRTask) => void) {
  const [state, setState] = createStore<{ tasks: OCRTask[]; revisions: Record<string, number> }>({ tasks: [], revisions: {} })
  let running = false
  let generation = 0
  let disposed = false
  const replace = (id: string, change: Partial<OCRTask>) => setState('tasks', (task) => task.id === id, change)
  const active = () => state.tasks.filter((task) => task.status === 'queued' || task.status === 'running')
  const taskFor = (noteId: NoteId) => [...state.tasks].reverse().find((task) => task.noteId === noteId)
  const pump = async () => {
    if (running || disposed) return
    const next = state.tasks.find((task) => task.status === 'queued')
    if (!next) return
    const startedGeneration = generation
    const id = next.id
    const noteId = next.noteId
    running = true
    replace(id, { status: 'running', error: undefined })
    try {
      const current = await client.note(noteId)
      if (disposed || startedGeneration !== generation) return
      const page = documentPageMetadata(current)
      if (!page) throw new Error('This note is not a document page.')
      replace(id, { notebookId: current.notebookId, pageNumber: page.pageNumber })
      if (current.readOnly && (next.forceOCR || page.textStatus === 'pending')) throw new Error('This page is locked. Unlock the page before recognizing its text.')
      // A retry after a lost response first checks the persisted page state.
      const result = page.textStatus === 'complete' && !next.forceOCR ? current : await client.recognizeDocumentPage(noteId, next.forceOCR ?? false)
      if (disposed || startedGeneration !== generation) return
      onComplete(result)
      replace(id, { status: 'completed', finishedAt: new Date().toISOString() })
      setState('revisions', noteId, (value = 0) => value + 1)
    } catch (failure) {
      if (!disposed && startedGeneration === generation) {
        replace(id, { status: 'failed', error: failure instanceof Error ? failure.message : String(failure), finishedAt: new Date().toISOString() })
        const failedTask = state.tasks.find((task) => task.id === id)
        if (failedTask) onFailure?.(failure, { ...failedTask })
      }
    } finally {
      if (startedGeneration === generation) {
        running = false
        queueMicrotask(() => void pump())
      }
    }
  }
  const enqueue = (noteId: NoteId, label = 'Document page', pageNumber?: number, forceOCR = false) => {
    const existing = active().find((task) => task.noteId === noteId)
    if (existing) return existing.id
    const id = crypto.randomUUID()
    setState('tasks', (previous) => [...previous, { id, noteId, label, pageNumber, forceOCR, status: 'queued', createdAt: new Date().toISOString() }])
    queueMicrotask(() => void pump())
    return id
  }
  const retry = (id: string) => {
    const task = state.tasks.find((value) => value.id === id)
    if (!task || task.status !== 'failed' || active().some((value) => value.noteId === task.noteId)) return
    replace(id, { status: 'queued', error: undefined, finishedAt: undefined })
    queueMicrotask(() => void pump())
  }
  const cancel = (id: string) => {
    const task = state.tasks.find((value) => value.id === id)
    if (task?.status === 'queued') replace(id, { status: 'cancelled', finishedAt: new Date().toISOString() })
  }
  const clear = () => { generation += 1; running = false; setState({ tasks: [], revisions: {} }) }
  onCleanup(() => { disposed = true; clear() })
  return { tasks: () => state.tasks, active, taskFor, enqueue, retry, cancel, clear,
    revision: (noteId: NoteId) => state.revisions[noteId] ?? 0 }
}
