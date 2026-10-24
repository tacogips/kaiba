import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { noteId } from '../notes/ids'
import { DocumentPageTextView } from './DocumentPageTextView'

vi.mock('../state/appStore', () => ({ useApp: () => ({ client: { documentPageText: async () => ({
  pageNumber: 4, text: 'Plain text\n\n# Not a heading\n<img src="x">', textSource: 'ocr', ocrState: 'complete',
}) } }) }))

test('displays exact page text without interpreting Markdown or HTML', async () => {
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentPageTextView noteId={noteId('page-4')} />, host)
  try {
    await vi.waitFor(() => expect(host.querySelector('pre')?.textContent).toBe('Plain text\n\n# Not a heading\n<img src="x">'))
    expect(host.querySelector('img, h1')).toBeNull()
  } finally { dispose(); host.remove() }
})
