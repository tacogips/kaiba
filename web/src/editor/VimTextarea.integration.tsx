import { createSignal } from 'solid-js'
import { createStore } from 'solid-js/store'
import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import type { WebAppSettings } from '../notes/settings'
import { createVimTextarea } from './VimTextarea'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

function mount(initial: string, settings: Partial<WebAppSettings> = {}) {
  const [state, setState] = createStore({ settings: { fontScale: 1.15, ...settings } as WebAppSettings })
  fixture.app = { state }
  const save = vi.fn()
  const close = vi.fn()
  const [text, setText] = createSignal(initial)
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => {
    const vim = createVimTextarea({ save, close })
    return <form>
      <textarea ref={vim.ref} value={text()} onInput={(event) => setText(event.currentTarget.value)} />
      <vim.Status />
    </form>
  }, host)
  const textarea = host.querySelector('textarea')!
  textarea.focus()
  textarea.setSelectionRange(0, 0)
  const press = (key: string, init: KeyboardEventInit = {}) => {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init })
    textarea.dispatchEvent(event)
    return event
  }
  const type = (keys: string) => { for (const key of keys) press(key) }
  const mode = () => host.querySelector('.vim-status-mode')?.textContent ?? null
  return { host, textarea, text, setText, setState, save, close, press, type, mode, dispose: () => { dispose(); host.remove() } }
}

describe('Vim textarea', () => {
  test('starts in normal mode by default and edits through Vim commands', async () => {
    const view = mount('alpha beta\ngamma')
    try {
      expect(view.mode()).toBe('NORMAL')
      expect(view.press('x').defaultPrevented).toBe(true)
      expect(view.textarea.value).toBe('lpha beta\ngamma')
      // Solid's onInput saw the edit through the synthetic input event.
      expect(view.text()).toBe('lpha beta\ngamma')
      view.type('dd')
      expect(view.text()).toBe('gamma')
      view.type('u')
      expect(view.text()).toBe('lpha beta\ngamma')
      view.type('jp')
      expect(view.text()).toBe('lpha beta\ngamma\nlpha beta')
      // The block cursor is the one selected character under the cursor.
      view.type('gg0')
      expect([view.textarea.selectionStart, view.textarea.selectionEnd]).toEqual([0, 1])
      expect(view.textarea.dataset.vimMode).toBe('normal')
    } finally { view.dispose() }
  })

  test('lets insert mode type natively and Escape return to normal mode', () => {
    const view = mount('abc')
    try {
      view.press('i')
      expect(view.mode()).toBe('INSERT')
      expect(view.press('z').defaultPrevented).toBe(false)
      expect(view.press('Escape').defaultPrevented).toBe(true)
      expect(view.mode()).toBe('NORMAL')
      // Normal mode refuses native text insertion.
      const blocked = new InputEvent('beforeinput', { inputType: 'insertText', data: 'q', bubbles: true, cancelable: true })
      view.textarea.dispatchEvent(blocked)
      expect(blocked.defaultPrevented).toBe(true)
    } finally { view.dispose() }
  })

  test('runs :w and :q as the editor save and close actions', async () => {
    const view = mount('note')
    try {
      view.press(':')
      await settle()
      const prompt = view.host.querySelector<HTMLInputElement>('.vim-status-prompt input')!
      expect(prompt).not.toBeNull()
      prompt.value = 'wq'
      prompt.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      expect(view.save).toHaveBeenCalledOnce()
      expect(view.close).toHaveBeenCalledOnce()
      expect(view.host.querySelector('.vim-status-prompt')).toBeNull()
    } finally { view.dispose() }
  })

  test('leaves Command shortcuts to the app', () => {
    const view = mount('abc')
    try {
      expect(view.press('t', { metaKey: true, shiftKey: true }).defaultPrevented).toBe(false)
      expect(view.press('k', { ctrlKey: true }).defaultPrevented).toBe(false)
      expect(view.textarea.value).toBe('abc')
    } finally { view.dispose() }
  })

  test('adopts value changes made outside Vim', () => {
    const view = mount('first')
    try {
      view.setText('second line')
      view.press('x')
      expect(view.text()).toBe('econd line')
    } finally { view.dispose() }
  })

  test('follows the vimMode setting and applies a custom keymap', () => {
    const view = mount('abc', { vimMode: false })
    try {
      expect(view.mode()).toBeNull()
      expect(view.press('x').defaultPrevented).toBe(false)
      expect(view.textarea.dataset.vimMode).toBeUndefined()
      view.setState('settings', 'vimMode', true)
      expect(view.mode()).toBe('NORMAL')
      view.setState('settings', 'vimKeymap', JSON.stringify({ version: 1, maps: { i: [{ lhs: 'jk', rhs: '<Esc>' }] } }))
      view.press('i')
      expect(view.press('j').defaultPrevented).toBe(true)
      view.press('k')
      expect(view.mode()).toBe('NORMAL')
      expect(view.text()).toBe('abc')
    } finally { view.dispose() }
  })
  test('Shift+V selects complete logical lines and j/k keep the moving end', () => {
    const view = mount('abcd\nefgh\nijkl')
    try {
      const bubble = vi.fn()
      window.addEventListener('keydown', bubble)
      try {
        view.press('V', { shiftKey: true })
        expect(view.mode()).toBe('VISUAL LINE')
        expect(view.textarea.value.slice(view.textarea.selectionStart, view.textarea.selectionEnd)).toBe('abcd')
        view.press('j')
        expect(view.textarea.value.slice(view.textarea.selectionStart, view.textarea.selectionEnd)).toBe('abcd\nefgh')
        view.press('k')
        expect(view.textarea.value.slice(view.textarea.selectionStart, view.textarea.selectionEnd)).toBe('abcd')
        expect(bubble).not.toHaveBeenCalled()
      } finally { window.removeEventListener('keydown', bubble) }
    } finally { view.dispose() }
  })

  test('Ctrl+V selects a rectangle and deletes only the selected columns', () => {
    const view = mount('abcd\nefgh\nijkl')
    try {
      view.press('l')
      expect(view.press('v', { ctrlKey: true, code: 'KeyV' }).defaultPrevented).toBe(true)
      expect(view.mode()).toBe('VISUAL BLOCK')
      view.type('jl')
      expect(view.textarea.dataset.vimMode).toBe('visual-block')
      expect(document.querySelector('.vim-block-selection')).not.toBeNull()
      view.press('d')
      expect(view.text()).toBe('ad\neh\nijkl')
      expect(view.mode()).toBe('NORMAL')
      expect(document.querySelector('.vim-block-selection')).toBeNull()
      view.press('u')
      expect(view.text()).toBe('abcd\nefgh\nijkl')
      view.press('i')
      expect(view.press('v', { ctrlKey: true, code: 'KeyV' }).defaultPrevented).toBe(false)
      expect(view.press('v', { metaKey: true, code: 'KeyV' }).defaultPrevented).toBe(false)
    } finally { view.dispose() }
  })

  test('native copy and cut use the whole selected rectangle', () => {
    const view = mount('abcd\nefgh')
    try {
      view.press('l'); view.press('v', { ctrlKey: true }); view.type('jl')
      const setData = vi.fn()
      const copy = new Event('copy', { bubbles: true, cancelable: true })
      Object.defineProperty(copy, 'clipboardData', { value: { setData } })
      view.textarea.dispatchEvent(copy)
      expect(copy.defaultPrevented).toBe(true)
      expect(setData).toHaveBeenCalledWith('text/plain', 'bc\nfg')
      const cut = new Event('cut', { bubbles: true, cancelable: true })
      Object.defineProperty(cut, 'clipboardData', { value: { setData } })
      view.textarea.dispatchEvent(cut)
      expect(cut.defaultPrevented).toBe(true)
      expect(view.text()).toBe('ad\neh')
    } finally { view.dispose() }
  })

})
