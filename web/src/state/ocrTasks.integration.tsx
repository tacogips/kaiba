import { createRoot } from 'solid-js'
import { expect, test, vi } from 'vitest'
import { createOCRTasks } from './ocrTasks'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { testDocumentPage } from '../notes/documentPageFixtures'

const page = (id: string, complete = false): Note => ({ noteId: noteId(id), notebookId: notebookId('pdf'), noteNumber: Number(id.slice(-1)) || 1,
  title: id, bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '', documentPage: testDocumentPage({ textStatus: complete ? 'complete' : 'pending' }) })
function mount(overrides: Record<string, unknown> = {}, onFailure?: (error: unknown) => void) {
  const finishes = new Map<string, (value: Note) => void>()
  const recognize = vi.fn((id: string) => new Promise<Note>((resolve) => finishes.set(id, resolve)))
  const read = vi.fn(async (id: string) => page(id))
  const complete = vi.fn()
  let dispose!: () => void
  const tasks = createRoot((cleanup) => { dispose = cleanup; return createOCRTasks({ note: read, recognizeDocumentPage: recognize, ...overrides } as unknown as NoteGraphQLClient, complete, onFailure) })
  return { tasks, recognize, read, complete, finishes, dispose }
}

test('serializes OCR, deduplicates a page, cancels queued work, and advances after completion', async () => {
  const view = mount()
  try {
    const first = view.tasks.enqueue(noteId('page-1'), 'Document', 1)
    expect(view.tasks.enqueue(noteId('page-1'))).toBe(first)
    const second = view.tasks.enqueue(noteId('page-2'), 'Document', 2)
    view.tasks.enqueue(noteId('page-3'), 'Document', 3)
    await vi.waitFor(() => expect(view.recognize).toHaveBeenCalledTimes(1))
    expect(view.tasks.active()).toHaveLength(3)
    expect(view.tasks.taskFor(noteId('page-1'))?.status).toBe('running')
    view.tasks.cancel(second)
    view.finishes.get('page-1')!(page('page-1', true))
    await vi.waitFor(() => expect(view.recognize).toHaveBeenCalledTimes(2))
    expect(view.recognize).toHaveBeenLastCalledWith('page-3', false)
    view.finishes.get('page-3')!(page('page-3', true))
    await vi.waitFor(() => expect(view.tasks.active()).toHaveLength(0))
    expect(view.tasks.taskFor(noteId('page-2'))?.status).toBe('cancelled')
    expect(view.tasks.revision(noteId('page-1'))).toBe(1)
  } finally { view.dispose() }
})

test('lost-response retry checks persisted completion instead of starting duplicate OCR', async () => {
  const read = vi.fn().mockResolvedValueOnce(page('page-1')).mockResolvedValue(page('page-1', true))
  const recognize = vi.fn().mockRejectedValue(new Error('Lost response'))
  const view = mount({ note: read, recognizeDocumentPage: recognize })
  try {
    const id = view.tasks.enqueue(noteId('page-1'))
    await vi.waitFor(() => expect(view.tasks.taskFor(noteId('page-1'))?.status).toBe('failed'))
    expect(view.tasks.taskFor(noteId('page-1'))?.error).toBe('Lost response')
    view.tasks.retry(id)
    await vi.waitFor(() => expect(view.tasks.taskFor(noteId('page-1'))?.status).toBe('completed'))
    expect(recognize).toHaveBeenCalledTimes(1)
  } finally { view.dispose() }
})

test('an explicitly locked page fails visibly without running recognition', async () => {
  const view = mount({ note: async () => ({ ...page('page-1'), readOnly: true }) })
  try {
    view.tasks.enqueue(noteId('page-1'))
    await vi.waitFor(() => expect(view.tasks.taskFor(noteId('page-1'))?.error).toContain('locked'))
    expect(view.recognize).not.toHaveBeenCalled()
  } finally { view.dispose() }
})

test('account reset invalidates in-flight lookups before they can start OCR', async () => {
  let resolve!: (value: Note) => void
  const view = mount({ note: () => new Promise<Note>((done) => { resolve = done }) })
  try {
    view.tasks.enqueue(noteId('page-1'))
    await vi.waitFor(() => expect(resolve).toBeDefined())
    view.tasks.clear(); resolve(page('page-1'))
    await Promise.resolve(); await Promise.resolve()
    expect(view.recognize).not.toHaveBeenCalled()
    expect(view.tasks.tasks()).toHaveLength(0)
    expect(view.complete).not.toHaveBeenCalled()
  } finally { view.dispose() }
})


test('authentication failure can clear the queue before another page request is issued', async () => {
  const failure = vi.fn(() => view.tasks.clear())
  const view = mount({ note: vi.fn(async () => { throw new Error('Authentication expired') }) }, failure)
  try {
    view.tasks.enqueue(noteId('page-1')); view.tasks.enqueue(noteId('page-2'))
    await vi.waitFor(() => expect(failure).toHaveBeenCalledTimes(1))
    expect(view.tasks.tasks()).toHaveLength(0)
    expect(view.recognize).not.toHaveBeenCalled()
  } finally { view.dispose() }
})

 test('explicit OCR runs again on a completed page instead of silently succeeding', async () => {
  const recognize = vi.fn(async () => page('page-1', true))
  const view = mount({ note: async () => page('page-1', true), recognizeDocumentPage: recognize })
  try {
    view.tasks.enqueue(noteId('page-1'), 'PDF', 1, true)
    await vi.waitFor(() => expect(view.tasks.taskFor(noteId('page-1'))?.status).toBe('completed'))
    expect(recognize).toHaveBeenCalledWith('page-1', true)
  } finally { view.dispose() }
})
