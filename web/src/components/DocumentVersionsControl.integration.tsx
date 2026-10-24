import { createSignal } from 'solid-js'
import { createStore } from 'solid-js/store'
import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { DocumentVersionsControl, type DocumentDisplayMode, type DocumentTranslationVersion } from './DocumentVersionsControl'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app }))

function mount(available: DocumentTranslationVersion[] = []) {
  const [state, setState] = createStore({ catalogRevision: 0 })
  const versions = vi.fn(async (_id: string) => available)
  const translate = vi.fn(async (_input: unknown) => ({ status: 'queued' }))
  fixture.app = { state, client: { documentPageTranslations: versions, requestNotebookTranslation: translate } }
  const [source, setSource] = createSignal(noteId('page-4'))
  const [mode, setMode] = createSignal<DocumentDisplayMode>('original')
  const [selected, setSelected] = createSignal<DocumentTranslationVersion>()
  const onSelect = vi.fn((next: DocumentDisplayMode, version?: DocumentTranslationVersion) => { setMode(next); setSelected(version) })
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentVersionsControl notebookId={notebookId('pdf')} sourceNoteId={source()} pageNumber={4}
    totalPages={12} displayMode={mode()} selectedTranslationId={selected()?.noteId} onSelect={onSelect} />, host)
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>('button')]
    .find((item) => (item.getAttribute('aria-label') ?? item.textContent) === label)!
  const input = (selector: string, value: string, event = 'input') => {
    const element = host.querySelector<HTMLInputElement | HTMLSelectElement>(selector)!
    element.value = value
    element.dispatchEvent(new Event(event, { bubbles: true }))
  }
  const open = () => button('Translate pages').click()
  const submit = () => host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  const close = () => { dispose(); host.remove() }
  return { host, versions, translate, button, input, open, submit, close, setState, setSource, onSelect }
}

describe('PDF header versions and translation', () => {
  test('switches Original/OCR and disables Translated when no version exists', async () => {
    const view = mount()
    try {
      await vi.waitFor(() => expect(view.versions).toHaveBeenCalledWith('page-4'))
      expect(view.button('Translated').disabled).toBe(true)
      view.button('OCR').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('text')
      expect(view.button('OCR').getAttribute('aria-pressed')).toBe('true')
      view.button('Original').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('original')
    } finally { view.close() }
  })

  test('selects saved languages and reloads versions when the source or catalog changes', async () => {
    const english = { noteId: noteId('en'), notebookId: notebookId('translated'), targetLanguage: 'English', text: 'Hello', sourceNoteId: noteId('page-4') }
    const french = { ...english, noteId: noteId('fr'), targetLanguage: 'French', text: 'Bonjour' }
    const view = mount([english, french])
    try {
      await vi.waitFor(() => expect(view.button('Translated').disabled).toBe(false))
      view.button('Translated').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('translation', english)
      view.input('[aria-label="Translation language"]', 'fr', 'change')
      expect(view.onSelect).toHaveBeenLastCalledWith('translation', french)
      expect(view.button('Translated').title).toContain('French')
      view.setState('catalogRevision', 1)
      await vi.waitFor(() => expect(view.versions).toHaveBeenCalledTimes(2))
      view.setSource(noteId('page-5'))
      await vi.waitFor(() => expect(view.versions).toHaveBeenLastCalledWith('page-5'))
    } finally { view.close() }
  })

  test('keeps the chosen language across pages, adopts updated text, and clears pages without a version', async () => {
    const english = { noteId: noteId('en4'), notebookId: notebookId('translated'), targetLanguage: 'English', text: 'Hello', sourceNoteId: noteId('page-4') }
    const french = { ...english, noteId: noteId('fr4'), targetLanguage: 'French', text: 'Bonjour' }
    const view = mount([english, french])
    try {
      await vi.waitFor(() => expect(view.button('Translated').disabled).toBe(false))
      view.button('Translated').click()
      view.input('[aria-label="Translation language"]', 'fr4', 'change')
      const page5 = { ...french, noteId: noteId('fr5'), sourceNoteId: noteId('page-5'), text: 'Page cinq' }
      view.versions.mockResolvedValueOnce([{ ...english, noteId: noteId('en5'), sourceNoteId: noteId('page-5') }, page5])
      view.setSource(noteId('page-5'))
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', page5))
      const updated = { ...page5, text: 'Page cinq, updated' }
      view.versions.mockResolvedValueOnce([updated])
      view.setState('catalogRevision', 1)
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', updated))
      const count = view.onSelect.mock.calls.length
      await Promise.resolve()
      expect(view.onSelect).toHaveBeenCalledTimes(count)
      view.versions.mockResolvedValueOnce([])
      view.setSource(noteId('page-6'))
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', undefined))
      expect(view.button('Translated').disabled).toBe(true)
    } finally { view.close() }
  })

  test('requests current page, validates inclusive ranges, and omits bounds for the whole document', async () => {
    const view = mount()
    try {
      view.open()
      view.input('input', ' English ')
      view.submit()
      await vi.waitFor(() => expect(view.translate).toHaveBeenCalledWith({ notebookId: 'pdf', targetLanguage: 'English', pageStart: 4, pageEnd: 4 }))
      await vi.waitFor(() => expect(view.host.querySelector('[role="status"]')?.textContent).toContain('queued'))
      view.input('[aria-label="Pages to translate"]', 'range', 'change')
      view.input('[aria-label="First page"]', '7')
      view.input('[aria-label="Last page"]', '2')
      expect(view.button('Request translation').disabled).toBe(true)
      view.submit()
      expect(view.translate).toHaveBeenCalledTimes(1)
      view.input('[aria-label="Last page"]', '13')
      expect(view.button('Request translation').disabled).toBe(true)
      view.input('[aria-label="Last page"]', '9')
      view.submit()
      await vi.waitFor(() => expect(view.translate).toHaveBeenLastCalledWith({ notebookId: 'pdf', targetLanguage: 'English', pageStart: 7, pageEnd: 9 }))
      await vi.waitFor(() => expect(view.button('Request translation').disabled).toBe(false))
      view.input('[aria-label="Pages to translate"]', 'all', 'change')
      view.submit()
      await vi.waitFor(() => expect(view.translate).toHaveBeenLastCalledWith({ notebookId: 'pdf', targetLanguage: 'English' }))
    } finally { view.close() }
  })

  test('reports unavailable agents and retryable failures, and closes with Escape', async () => {
    const view = mount()
    try {
      view.translate.mockRejectedValueOnce(new Error('Translation service unavailable'))
      view.open()
      view.input('input', 'French')
      view.submit()
      await vi.waitFor(() => expect(view.host.querySelector('[role="alert"]')?.textContent).toContain('Translation service unavailable'))
      view.translate.mockResolvedValueOnce({ status: 'agent-unavailable' })
      view.submit()
      await vi.waitFor(() => expect(view.host.querySelector('[role="status"]')?.textContent).toContain('not queued'))
      view.host.querySelector('form')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      expect(view.host.querySelector('form')).toBeNull()
      expect(view.button('Translate pages').getAttribute('aria-expanded')).toBe('false')
      expect(document.activeElement).toBe(view.button('Translate pages'))
    } finally { view.close() }
  })
})
