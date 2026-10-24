import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { DocumentPageOCRControl } from './DocumentPageOCRControl'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app }))

test('right-pane OCR supports retry and recognizes the selected physical page', async () => {
  const [state, setState] = createSignal('pending')
  const note = () => ({ noteId: noteId('page-4'), notebookId: notebookId('pdf'), noteNumber: 4, readOnly: false,
    bodyMarkdown: '', createdAt: '', updatedAt: '', tags: [], metaJSON: JSON.stringify({ documentPage: {
      pageNumber: 4, ocrState: state(), originFileId: 'file-pdf', originMediaType: 'application/pdf', analysis: {},
    } }) })
  const recognize = vi.fn(async () => {}).mockRejectedValueOnce(new Error('Try again'))
  fixture.app = { state: { get note() { return note() }, noteId: noteId('page-4') },
    client: { recognizeDocumentPage: recognize }, loadNotes: vi.fn(async () => {}), refreshNote: async () => { setState('complete') } }
  const host = document.createElement('aside')
  document.body.append(host)
  const dispose = render(() => <DocumentPageOCRControl />, host)
  try {
    host.querySelector('button')!.click()
    await vi.waitFor(() => expect(host.textContent).toContain('Try again'))
    host.querySelector('button')!.click()
    await vi.waitFor(() => expect(host.textContent).toContain('Searchable'))
    expect(recognize).toHaveBeenLastCalledWith('page-4')
    expect(host.querySelector('button')).toBeNull()
  } finally { dispose(); host.remove() }
})
