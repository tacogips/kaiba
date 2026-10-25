import { afterEach, expect, test, vi } from 'vitest'
import { readerControlPage, scrollReader } from './readerKeyboard'

afterEach(() => { document.body.replaceChildren(); vi.restoreAllMocks() })
function key(key: string, init: KeyboardEventInit = {}) { return new KeyboardEvent('keydown', { key, cancelable: true, bubbles: true, ...init }) }
function reader() {
  const element = document.createElement('article'); document.body.append(element)
  Object.defineProperty(element, 'clientHeight', { value: 600 })
  const scroll = vi.fn(); element.scrollBy = scroll
  return { element, scroll }
}
test('note reader pages with Ctrl-D/U and scrolls with j/k, including repeats', () => {
  const { element, scroll } = reader()
  for (const event of [key('d', { ctrlKey: true }), key('u', { ctrlKey: true }), key('j', { repeat: true }), key('k')]) {
    expect(scrollReader(event, element)).toBe(true); expect(event.defaultPrevented).toBe(true)
  }
  expect(scroll.mock.calls.map(([options]) => options.top)).toEqual([540, -540, 48, -48])
})
test('physical Control key codes work when the keyboard reports an unidentified key', () => {
  expect(readerControlPage(key('Unidentified', { ctrlKey: true, code: 'KeyD' }))).toBe(1)
  expect(readerControlPage(key('Unidentified', { ctrlKey: true, code: 'KeyU' }))).toBe(-1)
})
test('reader header controls keep page shortcuts active while another pane stays isolated', () => {
  const main = document.createElement('main'); main.className = 'reader'; document.body.append(main)
  const header = document.createElement('button'); const body = document.createElement('article')
  main.append(header, body)
  Object.defineProperty(body, 'clientHeight', { value: 600 }); body.scrollBy = vi.fn()
  header.addEventListener('keydown', (event) => scrollReader(event, body))
  header.focus(); header.dispatchEvent(key('d', { ctrlKey: true }))
  expect(body.scrollBy).toHaveBeenCalledWith({ top: 540, behavior: 'instant' })
})
test('PDF line scrolling uses its visible inner viewport and leaves page turns to the document reader', () => {
  const { element, scroll } = reader()
  const hidden = document.createElement('div'); hidden.className = 'pdf-viewer-stage'; hidden.hidden = true
  const text = document.createElement('section'); text.className = 'pdf-text-stage'; text.scrollBy = vi.fn()
  element.append(hidden, text)
  expect(scrollReader(key('j'), element, false)).toBe(true)
  expect(text.scrollBy).toHaveBeenCalledWith({ top: 48, behavior: 'instant' }); expect(scroll).not.toHaveBeenCalled()
  expect(scrollReader(key('d', { ctrlKey: true }), element, false)).toBe(false)
})
test('editing, dialogs, other panes, IME and modified shortcuts are untouched', () => {
  const { element, scroll } = reader()
  element.addEventListener('keydown', (event) => scrollReader(event, element))
  for (const tag of ['input', 'textarea', 'select']) { const input = document.createElement(tag); element.append(input); input.dispatchEvent(key('j')); input.dispatchEvent(key('d', { ctrlKey: true })) }
  const editable = document.createElement('div'); editable.setAttribute('contenteditable', ''); element.append(editable); editable.dispatchEvent(key('j'))
  for (const init of [{ isComposing: true }, { metaKey: true }, { altKey: true }, { shiftKey: true }, { ctrlKey: true }]) expect(scrollReader(key('j', init), element)).toBe(false)
  const other = document.createElement('button'); document.body.append(other)
  other.addEventListener('keydown', (event) => expect(scrollReader(event, element)).toBe(false)); other.dispatchEvent(key('j'))
  const dialog = document.createElement('dialog'); dialog.open = true; document.body.append(dialog)
  expect(scrollReader(key('d', { ctrlKey: true }), element)).toBe(false); expect(scroll).not.toHaveBeenCalled()
})
