import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { noteId } from '../notes/ids'
import { DocumentPageTextView } from './DocumentPageTextView'

const fixture = vi.hoisted(() => ({ read: undefined as undefined | ((id: string) => Promise<{ pageNumber: number; text: string; textSource: string; textStatus: string }>), text: 'Plain text\n\n# Not a heading\n<img src="x">' }))

vi.mock('../state/appStore', () => ({ useApp: () => ({ state: { notebookRevisions: {} }, ocrTasks: { revision: () => 0, taskFor: () => undefined }, client: { documentPageText: async (id: string) => fixture.read ? fixture.read(id) : ({
  pageNumber: 4, text: fixture.text, textSource: 'ocr', textStatus: 'complete',
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


test('a processed blank page explains the outcome and offers explicit repeat OCR', async () => {
  const original = fixture.text
  fixture.text = ''
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <DocumentPageTextView noteId={noteId('blank-page')} />, host)
  try {
    await vi.waitFor(() => expect(host.textContent).toContain('No text was detected on this page.'))
    expect(host.querySelector('[aria-label="Run OCR again"]')).not.toBeNull()
  } finally { fixture.text = original; dispose(); host.remove() }
})


test('a late page-text failure cannot replace the current page or its OCR result', async () => {
  let rejectOld!: (failure: Error) => void
  const [selected, setSelected] = createSignal(noteId('old-page'))
  fixture.read = (id) => id === 'old-page' ? new Promise((_, reject) => { rejectOld = reject })
    : Promise.resolve({ pageNumber: 2, text: 'Current page text', textSource: 'ocr', textStatus: 'complete' })
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <DocumentPageTextView noteId={selected()} />, host)
  try {
    await vi.waitFor(() => expect(rejectOld).toBeDefined())
    setSelected(noteId('current-page'))
    await vi.waitFor(() => expect(host.querySelector('pre')?.textContent).toBe('Current page text'))
    rejectOld(new Error('Old page failed'))
    await Promise.resolve(); await Promise.resolve()
    expect(host.querySelector('[role="alert"]')).toBeNull()
    expect(host.querySelector('pre')?.textContent).toBe('Current page text')
  } finally { fixture.read = undefined; dispose(); host.remove() }
})
