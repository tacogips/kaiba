import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { DocumentPageOCRControl } from './DocumentPageOCRControl'
import { testDocumentPage } from '../notes/documentPageFixtures'
import { createOCRTasks } from '../state/ocrTasks'
import type { NoteGraphQLClient } from '../notes/client'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app }))

test('right-pane OCR uses the shared queue, supports retry, and recognizes the selected physical page', async () => {
  const [state, setState] = createSignal<'pending' | 'complete'>('pending')
  const note = () => ({ noteId: noteId('page-4'), notebookId: notebookId('pdf'), noteNumber: 4, title: 'Page 4', readOnly: false,
    bodyMarkdown: '', createdAt: '', updatedAt: '', tags: [], documentPage: testDocumentPage({
      pageNumber: 4, textStatus: state(), originFileId: 'file-pdf', originMediaType: 'application/pdf', analysis: {},
    }) })
  const recognize = vi.fn(async () => ({ ...note(), documentPage: { ...note().documentPage, textStatus: 'complete' as const } })).mockRejectedValueOnce(new Error('Try again'))
  const client = { note: async () => note(), recognizeDocumentPage: recognize } as unknown as NoteGraphQLClient
  fixture.app = { state: { get note() { return note() }, noteId: noteId('page-4') }, notebook: () => ({ title: 'PDF', readOnly: true }), client }
  const host = document.createElement('aside'); document.body.append(host)
  const dispose = render(() => {
    fixture.app.ocrTasks = createOCRTasks(client, () => setState('complete'))
    return <DocumentPageOCRControl />
  }, host)
  try {
    host.querySelector('button')!.click()
    await vi.waitFor(() => expect(host.textContent).toContain('Try again'))
    expect(host.textContent).toContain('Retry OCR')
    host.querySelector('button')!.click()
    await vi.waitFor(() => expect(host.textContent).toContain('Searchable'))
    expect(recognize).toHaveBeenLastCalledWith('page-4', true)
    expect(host.querySelector('button')?.textContent).toContain('Run OCR again')
    host.querySelector('button')!.click()
    await vi.waitFor(() => expect(recognize).toHaveBeenCalledTimes(3))
  } finally { dispose(); host.remove() }
})
