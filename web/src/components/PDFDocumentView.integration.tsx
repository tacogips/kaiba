import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { fileId } from '../notes/ids'
import { PDFDocumentView } from './PDFDocumentView'

const mocks = vi.hoisted(() => {
  const renderPage = vi.fn(() => ({ promise: Promise.resolve(), cancel: vi.fn() }))
  const getPage = vi.fn(async () => ({ getViewport: ({ scale }: { scale: number }) => ({ width: 600 * scale, height: 800 * scale }), render: renderPage }))
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

test('fit to page uses both dimensions, tracks resizing and page orientation, and manual zoom exits fit mode', async () => {
  vi.clearAllMocks()
  const observers: Array<() => void> = []
  const disconnect = vi.fn()
  vi.stubGlobal('ResizeObserver', class {
    constructor(callback: () => void) { observers.push(callback) }
    observe() {}
    disconnect = disconnect
  })
  const host = document.createElement('div')
  document.body.append(host)
  const [page, setPage] = createSignal(1)
  const dispose = render(() => <PDFDocumentView fileId={fileId('file-pdf')} pageNumber={page()} />, host)
  try {
    const stage = host.querySelector<HTMLDivElement>('.pdf-viewer-stage')!
    let width = 800, height = 600
    Object.defineProperties(stage, { clientWidth: { get: () => width }, clientHeight: { get: () => height } })
    observers[0]!()
    const canvas = host.querySelector('canvas')!
    await vi.waitFor(() => expect(parseFloat(canvas.style.height)).toBeGreaterThan(height))
    const fit = host.querySelector<HTMLButtonElement>('[aria-label="Fit to page"]')!
    fit.click()
    await vi.waitFor(() => expect(parseFloat(canvas.style.height)).toBeLessThanOrEqual(height))
    expect(parseFloat(canvas.style.width)).toBeLessThanOrEqual(width)
    expect(host.textContent).toContain('56%')
    expect(fit.getAttribute('aria-pressed')).toBe('true')
    // Opening a pane or expanding AI changes the available reader viewport.
    width = 400; height = 300
    observers[0]!()
    await vi.waitFor(() => expect(parseFloat(canvas.style.height)).toBeLessThanOrEqual(height))
    expect(parseFloat(canvas.style.width)).toBeLessThanOrEqual(width)
    // A landscape page must fit horizontally as well.
    mocks.getPage.mockResolvedValueOnce({
      getViewport: ({ scale }: { scale: number }) => ({ width: 1200 * scale, height: 600 * scale }), render: mocks.renderPage,
    })
    setPage(2)
    await vi.waitFor(() => expect(parseFloat(canvas.style.width)).toBeGreaterThan(390))
    expect(parseFloat(canvas.style.width)).toBeLessThanOrEqual(width)
    expect(parseFloat(canvas.style.height)).toBeLessThanOrEqual(height)
    host.querySelector<HTMLButtonElement>('[aria-label="Zoom in"]')!.click()
    await vi.waitFor(() => expect(fit.getAttribute('aria-pressed')).toBe('false'))
    expect(mocks.blob).toHaveBeenCalledTimes(1)
  } finally { dispose(); host.remove(); vi.unstubAllGlobals() }
  expect(disconnect).toHaveBeenCalledOnce()
})
