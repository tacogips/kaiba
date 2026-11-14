import { createSignal } from 'solid-js'
import { createStore } from 'solid-js/store'
import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { DocumentVersionsControl, type DocumentDisplayMode, type DocumentTranslationVersion } from './DocumentVersionsControl'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', () => ({ useApp: () => fixture.app }))

function mount(available: DocumentTranslationVersion[] = []) {
  const [state, setState] = createStore({ catalogRevision: 0, notebookRevisions: {} as Record<string, number> })
  const versions = vi.fn(async (_id: string) => available.map((version) => ({
    noteId: version.sourceNoteId, language: version.targetLanguage, body: version.text,
    isCurrent: version.isCurrent, updatedAt: '',
  })))
  const translate = vi.fn(async (_input: unknown) => ({ status: 'queued' }))
  fixture.app = { state, client: { noteTranslations: versions, requestNotebookTranslation: translate } }
  const [page, setPage] = createSignal({ pageNumber: 4 })
  const [source, setSource] = createSignal(noteId('page-4'))
  const [mode, setMode] = createSignal<DocumentDisplayMode>('original')
  const [selected, setSelected] = createSignal<DocumentTranslationVersion>()
  const onSelect = vi.fn((next: DocumentDisplayMode, version?: DocumentTranslationVersion) => { setMode(next); setSelected(version) })
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <DocumentVersionsControl notebookId={notebookId('pdf')} sourceNoteId={source()} pageNumber={page().pageNumber}
    totalPages={12} displayMode={mode()} selectedLanguage={selected()?.targetLanguage} onSelect={onSelect} />, host)
  const button = (label: string) => [...host.querySelectorAll<HTMLButtonElement>('button')]
    .find((item) => (item.getAttribute('aria-label') ?? item.textContent) === label)!
  const input = (selector: string, value: string, event = 'input') => {
    const element = host.querySelector<HTMLInputElement | HTMLSelectElement>(selector)!
    element.value = value
    element.dispatchEvent(new Event(event, { bubbles: true }))
  }
  const open = () => { button('Translation actions').click(); button('Translate pages').click() }
  const submit = () => host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
  const close = () => { dispose(); host.remove() }
  return { host, versions, translate, button, input, open, submit, close, setState, setSource, setPage, onSelect }
}

describe('PDF header versions and translation', () => {
  test('keeps both views available before recognition or translation', async () => {
    const view = mount()
    try {
      await vi.waitFor(() => expect(view.versions).toHaveBeenCalledWith('page-4'))
      expect(view.button('Translated').disabled).toBe(false)
      view.button('OCR').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('text')
      expect(view.button('OCR').getAttribute('aria-pressed')).toBe('true')
      view.button('Original').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('original')
    } finally { view.close() }
  })

  test('selects saved languages and reloads versions when the source or catalog changes', async () => {
    const english = { targetLanguage: 'English', text: 'Hello', sourceNoteId: noteId('page-4'), isCurrent: true }
    const french = { ...english, targetLanguage: 'French', text: 'Bonjour', isCurrent: false }
    const view = mount([english, french])
    try {
      await vi.waitFor(() => expect(view.button('Translated').title).toContain('English'))
      view.button('Translated').click()
      expect(view.onSelect).toHaveBeenLastCalledWith('translation', english)
      view.input('[aria-label="Translation language"]', 'French', 'change')
      expect(view.onSelect).toHaveBeenLastCalledWith('translation', french)
      expect(view.button('Translated').title).toContain('French')
      expect(view.button('Translated').title).toContain('outdated')
      view.setState('catalogRevision', 1)
      await vi.waitFor(() => expect(view.versions).toHaveBeenCalledTimes(2))
      view.setSource(noteId('page-5'))
      await vi.waitFor(() => expect(view.versions).toHaveBeenLastCalledWith('page-5'))
    } finally { view.close() }
  })

  test('keeps the chosen language across pages, adopts updated text, and clears pages without a version', async () => {
    const english = { targetLanguage: 'English', text: 'Hello', sourceNoteId: noteId('page-4'), isCurrent: true }
    const french = { ...english, targetLanguage: 'French', text: 'Bonjour' }
    const view = mount([english, french])
    try {
      await vi.waitFor(() => expect(view.button('Translated').title).toContain('English'))
      view.button('Translated').click()
      view.input('[aria-label="Translation language"]', 'French', 'change')
      const page5 = { ...french, sourceNoteId: noteId('page-5'), text: 'Page cinq' }
      view.versions.mockResolvedValueOnce([
        { noteId: noteId('page-5'), language: 'English', body: 'Hello', isCurrent: true, updatedAt: '' },
        { noteId: noteId('page-5'), language: 'French', body: 'Page cinq', isCurrent: true, updatedAt: '' },
      ])
      view.setSource(noteId('page-5'))
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', page5))
      const updated = { ...page5, text: 'Page cinq, updated' }
      view.versions.mockResolvedValueOnce([{ noteId: noteId('page-5'), language: 'French', body: updated.text, isCurrent: true, updatedAt: '' }])
      view.setState('catalogRevision', 1)
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', updated))
      const count = view.onSelect.mock.calls.length
      await Promise.resolve()
      expect(view.onSelect).toHaveBeenCalledTimes(count)
      view.versions.mockResolvedValueOnce([])
      view.setSource(noteId('page-6'))
      await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', undefined))
      expect(view.button('Translated').disabled).toBe(false)
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
      expect(view.button('Translation actions').getAttribute('aria-expanded')).toBe('false')
      expect(document.activeElement).toBe(view.button('Translation actions'))
    } finally { view.close() }
  })
})

test('split arrows expose actions even before OCR or translation exists', async () => {
  const view = mount()
  const enqueue = vi.fn()
  fixture.app.ocrTasks = { taskFor: () => undefined, enqueue }
  fixture.app.notebook = () => ({ title: 'PDF' })
  try {
    view.button('OCR actions').click()
    expect(view.button('OCR actions').getAttribute('aria-expanded')).toBe('true')
    view.button('Make page searchable').click()
    expect(enqueue).toHaveBeenCalledWith('page-4', 'PDF', 4, true)
    view.button('Translation actions').click()
    view.button('Translate pages').click()
    expect(view.host.querySelector('form')).not.toBeNull()
    view.button('Translated').click()
    expect(view.onSelect).toHaveBeenLastCalledWith('translation', undefined)
  } finally { view.close() }
})

test('a completed background translation appears on a notebook event without a catalog reload', async () => {
  const view = mount()
  try {
    await vi.waitFor(() => expect(view.versions).toHaveBeenCalledTimes(1))
    view.button('Translated').click()
    view.versions.mockResolvedValueOnce([{ noteId: noteId('page-4'), language: 'Japanese', body: '翻訳済み', isCurrent: true, updatedAt: '' }])
    view.setState('notebookRevisions', 'pdf', 1)
    await vi.waitFor(() => expect(view.onSelect).toHaveBeenLastCalledWith('translation', {
      sourceNoteId: 'page-4', targetLanguage: 'Japanese', text: '翻訳済み', isCurrent: true,
    }))
  } finally { view.close() }
})

test('translation options survive same-page refreshes and Escape works after focus leaves the popover', () => {
  const view = mount()
  try {
    view.open()
    view.input('input', 'English')
    view.setPage({ pageNumber: 4 })
    expect(view.host.querySelector('form')).not.toBeNull()
    expect(view.host.querySelector<HTMLInputElement>('input')?.value).toBe('English')
    document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(view.host.querySelector('form')).toBeNull()
    expect(document.activeElement).toBe(view.button('Translation actions'))
  } finally { view.close() }
})
