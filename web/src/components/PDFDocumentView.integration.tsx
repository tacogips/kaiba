import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { fileId } from '../notes/ids'
import { PDFDocumentView } from './PDFDocumentView'

const mocks = vi.hoisted(() => {
  const renderPage = vi.fn(() => ({ promise: Promise.resolve(), cancel: vi.fn() }))
  const getPage = vi.fn(async () => ({ getViewport: () => ({ width: 600, height: 800 }), render: renderPage }))
  const destroy = vi.fn(async () => {})
  const getDocument = vi.fn(() => ({ promise: Promise.resolve({ getPage }), destroy }))
  const blob = vi.fn(async () => new Blob(['PDF bytes'], { type: 'application/pdf' }))
  return { renderPage, getPage, destroy, getDocument, blob }
})
vi.mock('pdfjs-dist', () => ({ GlobalWorkerOptions: {}, getDocument: mocks.getDocument }))
vi.mock('../state/appStore', () => ({ useApp: () => ({ client: { noteFileBlob: mocks.blob } }) }))

test('renders selected PDF pages from one authenticated source fetch and destroys the document on unmount', async () => {
  vi.clearAllMocks()
  const host = document.createElement('div')
  document.body.append(host)
  const [page, setPage] = createSignal(1)
  const dispose = render(() => <PDFDocumentView fileId={fileId('file-pdf')} pageNumber={page()} />, host)
  try {
    await vi.waitFor(() => expect(mocks.getPage).toHaveBeenCalledWith(1))
    expect(mocks.blob).toHaveBeenCalledWith('file-pdf')
    expect(host.querySelector('canvas')?.getAttribute('aria-label')).toBe('PDF page 1')
    setPage(137)
    await vi.waitFor(() => expect(mocks.getPage).toHaveBeenCalledWith(137))
    expect(host.querySelector('canvas')?.getAttribute('aria-label')).toBe('PDF page 137')
    expect(mocks.blob).toHaveBeenCalledTimes(1)
    host.querySelector<HTMLButtonElement>('[aria-label="Zoom in"]')!.click()
    await vi.waitFor(() => expect(host.textContent).toContain('125%'))
    expect(mocks.blob).toHaveBeenCalledTimes(1)
  } finally { dispose(); host.remove() }
  expect(mocks.destroy).toHaveBeenCalledTimes(1)
})

test('reports a failed PDF fetch and retries without exposing OCR text', async () => {
  vi.clearAllMocks()
  mocks.blob.mockRejectedValueOnce(new Error('File request failed (503).'))
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <PDFDocumentView fileId={fileId('file-pdf')} pageNumber={2} />, host)
  try {
    await vi.waitFor(() => expect(host.textContent).toContain('File request failed (503).'))
    const retry = host.querySelector<HTMLButtonElement>('[aria-label="Retry PDF"]')!
    retry.click()
    await vi.waitFor(() => expect(mocks.getPage).toHaveBeenCalledWith(2))
    expect(mocks.blob).toHaveBeenCalledTimes(2)
    expect(host.querySelector('img')).toBeNull()
  } finally { dispose(); host.remove() }
})
