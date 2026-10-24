import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { TranslationLanguagePicker } from './TranslationLanguagePicker'

function mount() {
  const [language, setLanguage] = createSignal('')
  const change = vi.fn((value: string) => setLanguage(value))
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <TranslationLanguagePicker value={language()} disabled={false} onChange={change} />, host)
  const input = host.querySelector<HTMLInputElement>('input')!
  const type = (text: string) => { input.value = text; input.dispatchEvent(new InputEvent('input', { bubbles: true })) }
  const options = () => [...host.querySelectorAll<HTMLButtonElement>('[role="option"]')]
  return { host, input, type, options, change, language, close: () => { dispose(); host.remove() } }
}

describe('Target language selection', () => {
  test('lists languages and filters by prefix rather than substring', () => {
    const view = mount()
    try {
      expect(view.options().length).toBeGreaterThan(40)
      view.type('pO')
      expect(view.options().map((item) => item.textContent)).toEqual(['PolishPolski', 'PortuguesePortuguês', 'Portuguese (Brazil)Português do Brasil'])
      expect(view.language()).toBe('')
      view.options()[1]!.click()
      expect(view.language()).toBe('Portuguese')
      expect(view.input.value).toBe('Portuguese')
      expect(view.input.getAttribute('aria-expanded')).toBe('false')
      view.type('lish')
      expect(view.options()).toHaveLength(1)
      expect(view.options()[0]!.textContent).toBe('Use “lish”')
    } finally { view.close() }
  })

  test('filters native names and language codes and supports keyboard selection', () => {
    const view = mount()
    try {
      view.type('日本')
      expect(view.options()).toHaveLength(1)
      expect(view.options()[0]!.textContent).toContain('Japanese')
      view.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      expect(view.language()).toBe('Japanese')
      view.type('ko')
      expect(view.options()[0]!.textContent).toContain('Korean')
      view.input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
      expect(view.input.getAttribute('aria-expanded')).toBe('false')
      expect(view.language()).toBe('')
    } finally { view.close() }
  })

  test('retains exact typed language names and permits explicitly choosing custom languages', () => {
    const view = mount()
    try {
      view.type(' english ')
      expect(view.language()).toBe('English')
      view.type('Klingon')
      expect(view.language()).toBe('')
      view.options()[0]!.click()
      expect(view.language()).toBe('Klingon')
    } finally { view.close() }
  })
})
