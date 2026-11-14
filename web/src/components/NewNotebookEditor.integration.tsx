import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { NewNotebookEditor } from './NewNotebookEditor'

test('typing autosaves without a create button and shows saved in the top right', async () => {
  vi.useFakeTimers()
  const saved = { notebookId: 'saved', title: 'F', type: 'DOCUMENT', readOnly: false, tags: [] }
  const save = vi.fn(async () => saved)
  const remove = vi.fn(async () => {})
  const client = {
    initialize: async () => {}, appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
    saveNewNotebook: save, deleteNotebook: remove, notebook: async () => saved, notes: async () => [], streamHeaders: () => ({}),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client }}><NewNotebookEditor /></AppStoreProvider>, host)
  try {
    const input = host.querySelector('textarea')!
    expect(host.querySelector('[aria-label="Save notebook"]')).toBeNull()
    expect(host.textContent).not.toContain('Create notebook')
    input.value = 'F'; input.dispatchEvent(new Event('input', { bubbles: true }))
    await vi.advanceTimersByTimeAsync(2999)
    expect(save).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(save).toHaveBeenCalledTimes(1)
    expect(host.querySelector('.compose-top-actions [role="status"]')?.textContent).toBe('Saved')
    expect(input.value).toBe('F')
    expect(input.disabled).toBe(false)
    host.querySelectorAll('button').forEach((button) => { if (button.textContent === 'Delete notebook') button.click() })
    await vi.advanceTimersByTimeAsync(1)
    expect(remove).toHaveBeenCalledWith('saved')
    expect(input.value).toBe('')
  } finally { dispose(); host.remove(); vi.useRealTimers() }
})

test('outlines and previews separate Markdown notes and keeps the title tied to the first line', async () => {
  const saved = { notebookId: 'saved', title: 'Notebook name', type: 'DOCUMENT', readOnly: false, tags: [] }
  const save = vi.fn(async () => saved)
  const client = {
    initialize: async () => {}, appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
    saveNewNotebook: save, notebook: async () => saved, notes: async () => [], streamHeaders: () => ({}),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client }}><NewNotebookEditor /></AppStoreProvider>, host)
  try {
    const source = 'Notebook name\n\n## A later heading\n**Bold first note**\n\\<><>\n\n<><>\n\n# Second note\n- One\n- Two'
    const input = host.querySelector('textarea')!
    input.value = source; input.dispatchEvent(new Event('input', { bubbles: true }))
    expect(host.querySelector('.compose-document-head h1')?.textContent).toBe('Notebook name')
    expect(host.querySelectorAll('.compose-note-entry')).toHaveLength(2)
    host.querySelector<HTMLButtonElement>('[title="Preview the separate notes"]')!.click()
    expect(host.querySelectorAll('.compose-preview-note')).toHaveLength(2)
    expect(host.querySelector('.compose-preview-note strong')?.textContent).toBe('Bold first note')
    expect(host.querySelector('.compose-preview-note')?.textContent).toContain('<><>')
    expect(host.querySelector('.compose-preview-note')?.textContent).not.toContain('\\<><>')
    expect(host.querySelectorAll('.compose-preview-note li')).toHaveLength(2)
    host.querySelector<HTMLButtonElement>('[title="Write Markdown"]')!.click()
    expect(host.querySelector('textarea')?.value).toBe(source)
    host.querySelector<HTMLButtonElement>('[aria-label="Add a note to this draft"]')!.click()
    expect(host.querySelectorAll('.compose-note-entry')).toHaveLength(3)
    expect(host.querySelector('textarea')?.value).toBe(source + '\n\n<><>\n\n')
  } finally { dispose(); host.remove() }
})
