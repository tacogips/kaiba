import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { NoteInfoTab } from './NoteInfoTab'
import { NoteTagsTab } from './NoteTagsTab'

const extract = vi.hoisted(() => vi.fn(async () => 'agent-unavailable'))

const rebuild = vi.hoisted(() => vi.fn(async () => ({ diagnostics: ['Rebuilt 25 pages and 3 AI turns. Search engine refresh queued.'] })))

vi.mock('../state/appStore', () => ({
  errorMessage: (error: unknown) => String(error),
  useApp: () => ({
    state: { notebookId: 'book', noteId: 'page-4', note: { noteNumber: 4, tags: [], notebookId: 'book' }, tags: [], tagClasses: [] },
    notebook: () => ({ title: 'Reading', readOnly: true, createdAt: '', updatedAt: '' }),
    client: { tagExtractionStatus: async () => 'none', requestTagExtraction: extract, rebuildNotebookSearchIndex: rebuild, notebookFiles: async () => [{ file: { originalFilename: 'source.pdf', mediaType: 'application/pdf', byteSize: 1024 } }] },
  }),
}))

test('Info shows document and file facts while Tags contains only tag tools', async () => {
  const info = document.createElement('div')
  const tags = document.createElement('div')
  document.body.append(info, tags)
  const closeInfo = render(() => <NoteInfoTab />, info)
  const closeTags = render(() => <NoteTagsTab />, tags)
  try {
    await vi.waitFor(() => expect(info.textContent).toContain('source.pdf'))
    expect(info.textContent).toContain('application/pdf')
    expect(info.textContent).toContain('Current page4')
    expect(info.textContent).not.toContain('Extract tags with agent')
    expect(tags.querySelector('button[aria-label="Extract tags with agent"]')).not.toBeNull()
    expect(info.querySelector('[aria-label="Translate notebook"]')).toBeNull()
    expect(tags.textContent).not.toContain('Created')
    expect(tags.textContent).not.toContain('File name')
  } finally { closeInfo(); closeTags(); info.remove(); tags.remove() }
})

test('Analysis can rebuild this notebook and its AI conversations and reports errors', async () => {
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <NoteInfoTab />, host)
  try {
    const button = [...host.querySelectorAll('button')].find((item) => item.textContent?.includes('Rebuild search index'))!
    button.click()
    await vi.waitFor(() => expect(rebuild).toHaveBeenCalledWith('book'))
    await vi.waitFor(() => expect(host.querySelector('[role="status"]')?.textContent).toContain('3 AI turns'))
    rebuild.mockRejectedValueOnce(new Error('Search unavailable'))
    button.click()
    await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain('Search unavailable'))
  } finally { dispose(); host.remove() }
})

test('unavailable tag extraction is an explicit error rather than an empty successful result', async () => {
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <NoteTagsTab />, host)
  try {
    host.querySelector<HTMLButtonElement>('[aria-label="Extract tags with agent"]')!.click()
    await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain('no AI agent is configured'))
  } finally { dispose(); host.remove() }
})
