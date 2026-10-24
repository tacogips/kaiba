import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { notebookId } from '../notes/ids'
import { NotebookTitleEditor } from './NotebookTitleEditor'

const mocks = vi.hoisted(() => ({ rename: vi.fn(async () => ({})), refresh: vi.fn(async () => {}) }))
vi.mock('../state/appStore', () => ({ useApp: () => ({ client: { renameNotebook: mocks.rename }, refreshCatalog: mocks.refresh }) }))

test('renames a read-only document and preserves the editor when saving fails', async () => {
  vi.clearAllMocks()
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <NotebookTitleEditor notebook={{ notebookId: notebookId('pdf-book'), type: 'DOCUMENT',
    title: 'source.pdf', readOnly: true, tags: [], createdAt: '', updatedAt: '' }} />, host)
  try {
    host.querySelector<HTMLButtonElement>('[aria-label="Rename document"]')!.click()
    const input = host.querySelector('input')!
    expect(input.value).toBe('source.pdf')
    input.value = 'My reading'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    const save = host.querySelector<HTMLButtonElement>('[aria-label="Save title"]')!
    expect(save.title).toBe('Save')
    expect(save.textContent).toBe('')
    expect(save.querySelector('svg')).not.toBeNull()
    expect(host.querySelector('h1')?.textContent).toBe('source.pdf')
    mocks.rename.mockRejectedValueOnce(new Error('Offline'))
    save.click()
    await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toBe('Offline'))
    expect(host.querySelector('input')?.value).toBe('My reading')
    expect(host.querySelector('form [role="alert"]')?.textContent).toBe('Offline')
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(host.querySelector('form')).toBeNull())
    expect(mocks.rename).toHaveBeenLastCalledWith('pdf-book', 'My reading')
    expect(mocks.refresh).toHaveBeenCalledTimes(1)
  } finally { dispose(); host.remove() }
})
