import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { NoteInfoTab } from './NoteInfoTab'
import { NoteTagsTab } from './NoteTagsTab'

vi.mock('../state/appStore', () => ({
  errorMessage: (error: unknown) => String(error),
  useApp: () => ({
    state: { notebookId: 'book', noteId: 'page-4', note: { noteNumber: 4, tags: [], notebookId: 'book' }, tags: [], tagClasses: [] },
    notebook: () => ({ title: 'Reading', readOnly: true, createdAt: '', updatedAt: '' }),
    client: { notebookFiles: async () => [{ file: { originalFilename: 'source.pdf', mediaType: 'application/pdf', byteSize: 1024 } }] },
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
