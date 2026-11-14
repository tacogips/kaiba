import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { DocumentImportForm } from './DocumentImportForm'

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

test('document import sends the file and zero-page limit once while busy', async () => {
  let finish: (() => void) | undefined
  const importer = vi.fn(() => new Promise<void>((resolve) => { finish = resolve }))
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentImportForm onImport={importer} />, host)
  try {
    const file = new File(['pdf'], 'book.pdf', { type: 'application/pdf' })
    const inputs = host.querySelectorAll('input')
    Object.defineProperty(inputs[0], 'files', { value: [file], configurable: true })
    inputs[0]!.dispatchEvent(new Event('change', { bubbles: true }))
    inputs[1]!.value = 'My document'
    inputs[1]!.dispatchEvent(new Event('input', { bubbles: true }))
    inputs[2]!.value = '0'
    inputs[2]!.dispatchEvent(new Event('input', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    expect(importer).toHaveBeenCalledExactlyOnceWith(file, 'My document', '0')
    expect(host.querySelector('button')!.disabled).toBe(true)
    finish!()
    await settle()
    expect(host.querySelector('button')!.disabled).toBe(true)
  } finally { dispose(); host.remove() }
})

test('oversized uploads are rejected and uncertain failures advise checking notebooks', async () => {
  const importer = vi.fn(async () => { throw new Error('Connection lost') })
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentImportForm onImport={importer} />, host)
  try {
    const input = host.querySelector('input')!
    Object.defineProperty(input, 'files', { value: [new File([new Uint8Array(1_048_577)], 'large.pdf')], configurable: true })
    input.dispatchEvent(new Event('change', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    expect(importer).not.toHaveBeenCalled()
    expect(host.textContent).toContain('up to 1 MiB')
    Object.defineProperty(input, 'files', { value: [new File(['image'], 'page.png')], configurable: true })
    input.dispatchEvent(new Event('change', { bubbles: true }))
    host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await settle()
    expect(host.querySelector('[role="alert"]')?.textContent).toContain('Check your notebooks before retrying')
    expect(host.textContent).toContain('Connection lost')
  } finally { dispose(); host.remove() }
})
