import { createSignal } from 'solid-js'
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

test('title edits dismiss outside or with global Escape, restore keyboard focus, and reset on notebook change', async () => {
  vi.clearAllMocks()
  const [id, setId] = createSignal('first')
  const host = document.createElement('div'); document.body.append(host)
  const outside = document.createElement('button'); document.body.append(outside)
  const dispose = render(() => <NotebookTitleEditor notebook={{ notebookId: notebookId(id()), type: 'DOCUMENT',
    title: `${id()}.pdf`, readOnly: true, tags: [], createdAt: '', updatedAt: '' }} />, host)
  try {
    const trigger = host.querySelector<HTMLButtonElement>('[aria-label="Rename document"]')!
    trigger.click()
    await vi.waitFor(() => expect(document.activeElement).toBe(host.querySelector('input')))
    host.querySelector('input')!.dispatchEvent(new Event('pointerdown', { bubbles: true }))
    expect(host.querySelector('form')).not.toBeNull()
    outside.dispatchEvent(new Event('pointerdown', { bubbles: true })); outside.focus()
    expect(host.querySelector('form')).toBeNull()
    expect(document.activeElement).toBe(outside)
    trigger.click(); await Promise.resolve()
    outside.focus()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(host.querySelector('form')).toBeNull()
    expect(document.activeElement).toBe(trigger)
    trigger.click(); setId('second')
    expect(host.querySelector('form')).toBeNull()
    expect(host.querySelector('h1')?.textContent).toBe('second.pdf')
    expect(mocks.rename).not.toHaveBeenCalled()
  } finally { dispose(); host.remove(); outside.remove() }
})
