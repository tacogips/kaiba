import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { DocumentImportForm } from './DocumentImportForm'

test('defaults the title to the filename and sends the import-specific extraction override', async () => {
  const importFile = vi.fn(async () => {})
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentImportForm onImport={importFile} />, host)
  try {
    const file = new File(['pdf'], 'Source document.pdf', { type: 'application/pdf' })
    const input = host.querySelector<HTMLInputElement>('input[type="file"]')!
    Object.defineProperty(input, 'files', { value: [file] })
    input.dispatchEvent(new Event('change', { bubbles: true }))
    const title = Array.from(host.querySelectorAll('input')).find((item) => item.value === file.name)!
    expect(title).toBeDefined()
    const mode = host.querySelector('select')!
    mode.value = 'ocr-only'; mode.dispatchEvent(new Event('change', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(importFile).toHaveBeenCalledWith(file, file.name, undefined, 'ocr-only'))
  } finally { dispose(); host.remove() }
})
