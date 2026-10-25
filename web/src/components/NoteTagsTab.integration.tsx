import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { NoteTagsTab } from './NoteTagsTab'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app, errorMessage: (error: unknown) => String(error) }))

function mount() {
  const status = vi.fn(async () => 'none')
  const refresh = vi.fn(async () => {})
  fixture.app = { state: { noteId: 'page-1', note: { tags: [{ tag: { tagId: 'tag-new', name: 'Ada Lovelace', classId: 'person' } }] },
    tags: [], tagClasses: [] }, client: { tagExtractionStatus: status, requestTagExtraction: vi.fn(async () => 'queued') }, refreshCatalog: refresh }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <NoteTagsTab />, host)
  return { host, status, refresh, close: () => { dispose(); host.remove() } }
}

test('shows provided tag names while the catalog catches up, and tracks a real request through completion', async () => {
  const view = mount()
  try {
    await vi.waitFor(() => expect(view.status).toHaveBeenCalledTimes(1))
    expect(view.host.textContent).toContain('Ada Lovelace')
    expect(view.host.textContent).not.toContain('[missing:')
    view.status.mockResolvedValueOnce('running').mockResolvedValue('completed')
    view.host.querySelector<HTMLButtonElement>('[aria-label="Extract tags with agent"]')!.click()
    await vi.waitFor(() => expect(view.host.querySelector<HTMLButtonElement>('[aria-label="Extract tags with agent"]')!.disabled).toBe(true))
    await vi.waitFor(() => expect(view.host.textContent).toContain('Tag extraction complete.'), { timeout: 2000 })
    expect(view.refresh).toHaveBeenCalledTimes(1)
  } finally { view.close() }
})

test('reopening a failed request shows an actionable error and permits retry', async () => {
  const view = mount()
  try {
    await vi.waitFor(() => expect(view.status).toHaveBeenCalledTimes(1))
    view.status.mockResolvedValue('failed')
    view.host.querySelector<HTMLButtonElement>('[aria-label="Extract tags with agent"]')!.click()
    await vi.waitFor(() => expect(view.host.querySelector('[role="alert"]')?.textContent).toContain('Check the AI provider'))
    expect(view.host.querySelector<HTMLButtonElement>('[aria-label="Extract tags with agent"]')!.disabled).toBe(false)
  } finally { view.close() }
})
