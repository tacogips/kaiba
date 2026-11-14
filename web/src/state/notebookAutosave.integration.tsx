import { createRoot } from 'solid-js'
import { expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import { notebookId } from '../notes/ids'
import type { Notebook } from '../notes/types'
import { createWritingDrafts } from './writingDrafts'
import { createNotebookAutosave } from './notebookAutosave'

function setup(create = vi.fn(async () => saved)) {
  const update = vi.fn(async () => saved)
  const remove = vi.fn(async () => {})
  const refresh = vi.fn(async () => {})
  let dispose!: () => void
  const value = createRoot((cleanup) => {
    dispose = cleanup
    const draft = createWritingDrafts().get('new-notebook-body')
    return { draft, autosave: createNotebookAutosave({ saveNewNotebook: create, saveNotebookDraft: update, deleteNotebook: remove } as unknown as NoteGraphQLClient, draft, refresh) }
  })
  return { ...value, create, update, remove, refresh, dispose }
}
const saved = { notebookId: notebookId('saved'), title: 'First', type: 'DOCUMENT', readOnly: false, tags: [] } as unknown as Notebook

test('one character creates after three quiet seconds; later edits update the same notebook', async () => {
  vi.useFakeTimers()
  const view = setup()
  try {
    view.draft.setText('F')
    await vi.advanceTimersByTimeAsync(2000)
    expect(view.create).not.toHaveBeenCalled()
    view.draft.setText('First')
    await vi.advanceTimersByTimeAsync(2999)
    expect(view.create).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(view.create).toHaveBeenCalledTimes(1)
    expect(view.autosave.status()).toBe('Saved')
    expect(view.draft.text()).toBe('First')
    view.draft.setText('First\n<><>\nSecond')
    await vi.advanceTimersByTimeAsync(3000)
    expect(view.create).toHaveBeenCalledTimes(1)
    expect(view.update).toHaveBeenCalledWith(saved.notebookId, 'First\n<><>\nSecond')
    expect(view.autosave.status()).toBe('Saved')
    expect(view.draft.baseText()).toBe(view.draft.text())
  } finally { view.dispose(); vi.useRealTimers() }
})

test('lost creation response retries its immutable source/key while typing remains available', async () => {
  vi.useFakeTimers()
  const create = vi.fn().mockRejectedValueOnce(new Error('Lost response')).mockResolvedValue(saved)
  const view = setup(create)
  try {
    view.draft.setText('F')
    await vi.advanceTimersByTimeAsync(3000)
    expect(view.autosave.status()).toBe('Save failed')
    view.draft.setText('Finished title')
    await vi.advanceTimersByTimeAsync(3000)
    expect(create.mock.calls[0]).toEqual(create.mock.calls[1])
    expect(view.autosave.status()).toBe('Unsaved changes')
    await vi.advanceTimersByTimeAsync(3000)
    expect(view.update).toHaveBeenCalledWith(saved.notebookId, 'Finished title')
    expect(view.autosave.status()).toBe('Saved')
  } finally { view.dispose(); vi.useRealTimers() }
})

test('delete cancels pending autosave and does not recreate the notebook', async () => {
  vi.useFakeTimers()
  const view = setup()
  try {
    view.draft.setText('F'); await vi.advanceTimersByTimeAsync(3000)
    view.draft.setText('Pending changes')
    await view.autosave.remove()
    await vi.advanceTimersByTimeAsync(6000)
    expect(view.remove).toHaveBeenCalledWith(saved.notebookId)
    expect(view.update).not.toHaveBeenCalled()
    expect(view.create).toHaveBeenCalledTimes(1)
    expect(view.draft.text()).toBe('')
    expect(view.autosave.notebook()).toBeUndefined()
  } finally { view.dispose(); vi.useRealTimers() }
})

test('delete resolves a lost creation response before removing the server notebook', async () => {
  vi.useFakeTimers()
  const create = vi.fn().mockRejectedValueOnce(new Error('Lost response')).mockResolvedValue(saved)
  const view = setup(create)
  try {
    view.draft.setText('F'); await vi.advanceTimersByTimeAsync(3000)
    await view.autosave.remove()
    expect(create.mock.calls[0]).toEqual(create.mock.calls[1])
    expect(view.remove).toHaveBeenCalledWith(saved.notebookId)
    expect(view.draft.text()).toBe('')
    await vi.advanceTimersByTimeAsync(6000)
    expect(create).toHaveBeenCalledTimes(2)
  } finally { view.dispose(); vi.useRealTimers() }
})
