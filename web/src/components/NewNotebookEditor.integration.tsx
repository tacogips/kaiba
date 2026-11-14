import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { NewNotebookEditor } from './NewNotebookEditor'

test('saving text creates a notebook without a title form and retries the same request', async () => {
  const saved = { notebookId: 'saved', title: 'First idea', type: 'DOCUMENT', readOnly: false, tags: [] }
  const save = vi.fn().mockRejectedValueOnce(new Error('Lost response')).mockResolvedValue(saved)
  const client = {
    initialize: async () => {}, appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
    saveNewNotebook: save, notebook: async () => saved, notes: async () => [], streamHeaders: () => ({}),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client }}><NewNotebookEditor /></AppStoreProvider>, host)
  try {
    const input = host.querySelector('textarea')!
    expect(input.hasAttribute('placeholder')).toBe(false)
    expect(host.querySelector('[aria-label="New notebook"] input')).toBeNull()
    input.value = '# First idea\nSome detail'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    const submit = () => host.querySelector('[aria-label="New notebook"]')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    submit()
    await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain('Lost response'))
    expect(input.value).toBe('# First idea\nSome detail')
    submit()
    await vi.waitFor(() => expect(input.value).toBe(''))
    expect(save.mock.calls[0]).toEqual(save.mock.calls[1])
    expect(save.mock.calls[0]![0]).toBe('# First idea\nSome detail')
  } finally { dispose(); host.remove() }
})
