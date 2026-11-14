import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { DocumentImportPopup } from './DocumentImportPopup'
const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))

test('imports in a popup from the current page, uses the saved default, and closes after success', async () => {
  const importDocument = vi.fn(async () => ({ notebookId: 'imported' }))
  const openNotebook = vi.fn(), close = vi.fn()
  fixture.app = { state: { route: { kind: 'home' }, settings: { pdfTextMode: 'ocr-only' } }, client: { importDocument }, refreshCatalog: vi.fn(async () => {}), openNotebook }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <DocumentImportPopup onClose={close} />, host)
  try {
    const popup = document.querySelector('[role="dialog"][aria-label="Import document"]')!
    expect(popup).not.toBeNull()
    const input = popup.querySelector<HTMLInputElement>('input[type="file"]')!
    const file = new File(['pdf'], 'Document.pdf', { type: 'application/pdf' })
    Object.defineProperty(input, 'files', { value: [file] }); input.dispatchEvent(new Event('change', { bubbles: true }))
    popup.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(importDocument).toHaveBeenCalledWith(file, 'Document.pdf', undefined, 'ocr-only'))
    await vi.waitFor(() => expect(openNotebook).toHaveBeenCalledWith('imported'))
    expect(close).toHaveBeenCalledOnce()
  } finally { dispose(); host.remove() }
})

test('Escape dismisses the popup without importing or changing the Markdown draft', () => {
  const close = vi.fn(), importDocument = vi.fn()
  fixture.app = { state: { route: { kind: 'home' }, settings: {} }, client: { importDocument } }
  const host = document.createElement('div')
  const dispose = render(() => <DocumentImportPopup onClose={close} />, host)
  try {
    document.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(close).toHaveBeenCalledOnce(); expect(importDocument).not.toHaveBeenCalled()
  } finally { dispose() }
})
