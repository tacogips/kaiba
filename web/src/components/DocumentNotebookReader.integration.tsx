import { createSignal, type JSX } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId, type FileId } from '../notes/ids'
import type { Note } from '../notes/types'
import { DocumentNotebookReader } from './DocumentNotebookReader'
import { MarkdownBody } from './Markdown'

vi.mock('pdfjs-dist', () => ({ GlobalWorkerOptions: {}, getDocument: () => ({
  promise: Promise.resolve({ getPage: vi.fn() }), destroy: async () => {},
}) }))

async function settle() {
  for (let index = 0; index < 4; index += 1) await new Promise((resolve) => setTimeout(resolve, 0))
}
function page(number: number, binding = 'right'): Note {
  return { noteId: noteId(`note-${number}`), notebookId: notebookId('book'), noteNumber: number, title: `Page ${number}`,
    bodyMarkdown: number === 1 ? 'First page text' : '', readOnly: false, createdAt: '', updatedAt: '', tags: [],
    metaJSON: JSON.stringify({ documentPage: { pageNumber: number, ocrState: number === 1 ? 'complete' : 'pending',
      originFileId: `file-${number}`, analysis: { writingMode: 'vertical', binding, language: 'ja' } } }) }
}
function mount(children: () => JSX.Element, loadBlob: (id: FileId) => Promise<Blob>) {
  const api = { initialize: async () => undefined, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [], noteFileBlob: loadBlob } as unknown as NoteGraphQLClient
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api,
    router: { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} },
  }}>{children()}</AppStoreProvider>, host)
  return { host, close: () => { dispose(); host.remove(); globalThis.fetch = originalFetch },
    button: (name: string) => [...host.querySelectorAll('button')].find((button) => (button.getAttribute('aria-label') ?? button.textContent) === name)! }
}

test('opening a document selects its first physical page for page-specific memos', async () => {
  const selected: string[] = []
  const harness = mount(() => <DocumentNotebookReader notes={[page(1), page(2)]} totalCount={2}
    onSelect={(note) => selected.push(note.noteId)} onLoadMore={async () => {}} />,
  async () => new Blob(['image'], { type: 'image/png' }))
  try {
    await settle()
    expect(selected).toEqual(['note-1'])
  } finally { harness.close() }
})

test('flips physical pages showing only original images and rejects stale image responses', async () => {
  const requests: string[] = []
  const resolvers = new Map<string, (blob: Blob) => void>()
  const createURL = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:current-page')
  const revokeURL = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
  const harness = mount(() => {
    const [selected, setSelected] = createSignal(noteId('note-1'))
    return <DocumentNotebookReader notes={[page(1), page(2, 'unknown')]} selectedNoteId={selected()} totalCount={2}
      onSelect={(note) => setSelected(note.noteId)} onLoadMore={async () => {}} />
  }, (id) => { requests.push(id); return new Promise((resolve) => resolvers.set(id, resolve)) })
  try {
    await settle()
    expect(requests).toEqual(['file-1'])
    expect(harness.host.textContent).not.toContain('First page text')
    expect(harness.host.querySelector(`[aria-label="${'Page display ' + 'mode'}"]`)).toBeNull()
    expect(harness.button('Text')).toBeUndefined()
    expect(harness.button('Original')).toBeUndefined()
    harness.host.querySelector('[aria-label="Document pages"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }))
    await settle()
    expect(requests).toEqual(['file-1', 'file-2'])
    resolvers.get('file-2')!(new Blob(['two'], { type: 'image/png' }))
    await settle()
    resolvers.get('file-1')!(new Blob(['one'], { type: 'image/png' }))
    await settle()
    expect(createURL).toHaveBeenCalledTimes(1)
    expect(harness.host.querySelector('img')?.alt).toBe('Original page 2')
    expect(harness.button('Next page').disabled).toBe(true)
    expect(harness.host.textContent).toContain('Page 2 / 2')
    harness.host.querySelector('[aria-label="Document pages"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await settle()
    expect(revokeURL).toHaveBeenCalledWith('blob:current-page')
    expect(harness.host.textContent).toContain('Page 1 / 2')
    expect(harness.host.textContent).not.toContain('First page text')
  } finally { harness.close(); vi.restoreAllMocks() }
})

test('loads the next note batch before navigating beyond the current batch', async () => {
  let loads = 0
  const harness = mount(() => {
    const [notes, setNotes] = createSignal([page(1, 'left')])
    const [selected, setSelected] = createSignal(noteId('note-1'))
    return <DocumentNotebookReader notes={notes()} selectedNoteId={selected()} totalCount={2}
      onSelect={(note) => setSelected(note.noteId)} onLoadMore={async () => { loads += 1; setNotes([page(1, 'left'), page(2, 'left')]) }} />
  }, async () => new Blob(['image'], { type: 'image/png' }))
  try {
    await settle()
    harness.host.querySelector('[aria-label="Document pages"]')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await settle()
    expect(loads).toBe(1)
    expect(harness.host.textContent).toContain('Page 2 / 2')
    expect(harness.button('Next page').disabled).toBe(true)
  } finally { harness.close() }
})

test('figure Markdown fetches local images through the client and never uses unsafe image schemes', async () => {
  const requests: string[] = []
  const createURL = vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:figure')
  const revokeURL = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {})
  const harness = mount(() => <MarkdownBody markdown={'![Figure](/files/file-figure)\n\n![Unsafe](javascript:alert)'} />,
    async (id) => { requests.push(id); return new Blob(['figure'], { type: 'image/png' }) })
  try {
    await settle()
    expect(requests).toEqual(['file-figure'])
    expect(harness.host.querySelectorAll('img')).toHaveLength(1)
    expect(harness.host.querySelector('img')?.getAttribute('src')).toBe('blob:figure')
    expect(harness.host.querySelector('img')?.alt).toBe('Figure')
    expect(createURL).toHaveBeenCalledTimes(1)
  } finally { harness.close(); expect(revokeURL).toHaveBeenCalledWith('blob:figure'); vi.restoreAllMocks() }
})

test('page notes never render OCR or fetch Markdown figure images', async () => {
  const requests: string[] = []
  const harness = mount(() => <DocumentNotebookReader notes={[{
    ...page(1), bodyMarkdown: 'Hidden OCR words ![Figure 1](/files/f1)',
    metaJSON: JSON.stringify({ documentPage: { pageNumber: 1, ocrState: 'complete', originFileId: 'file-origin', analysis: {} } }),
  }]} selectedNoteId={noteId('note-1')} totalCount={1} onSelect={() => {}} onLoadMore={async () => {}} />,
  async (id) => { requests.push(id); return new Blob(['origin'], { type: 'image/png' }) })
  try {
    await settle()
    expect(requests).toEqual(['file-origin'])
    expect(harness.host.textContent).not.toContain('Hidden OCR words')
    expect(harness.host.querySelectorAll('img')).toHaveLength(1)
    expect(harness.host.querySelector('img')?.alt).toBe('Original page 1')
  } finally { harness.close() }
})

test('non-page notes keep rendering Markdown while page notes stay image-only', async () => {
  const userNote: Note = { noteId: noteId('note-2'), notebookId: notebookId('book'), noteNumber: 2, title: 'Mine',
    bodyMarkdown: 'User authored words', readOnly: false, createdAt: '', updatedAt: '', tags: [] }
  let select: (id: ReturnType<typeof noteId>) => void = () => {}
  const harness = mount(() => {
    const [selected, setSelected] = createSignal(noteId('note-1'))
    select = setSelected
    return <DocumentNotebookReader notes={[page(1), userNote]} selectedNoteId={selected()} totalCount={2}
      onSelect={(note) => setSelected(note.noteId)} onLoadMore={async () => {}} />
  }, async () => new Blob(['image'], { type: 'image/png' }))
  try {
    await settle()
    expect(harness.host.textContent).not.toContain('First page text')
    expect(harness.host.textContent).not.toContain('User authored words')
    select(noteId('note-2'))
    await settle()
    expect(harness.host.textContent).toContain('User authored words')
    expect(harness.host.textContent).not.toContain('First page text')
  } finally { harness.close() }
})


test('page position stays in the footer and arrow keys navigate outside editable fields', async () => {
  const harness = mount(() => {
    const [selected, setSelected] = createSignal(noteId('note-1'))
    return <><input aria-label="Memo draft" /><DocumentNotebookReader notes={[page(1, 'left'), page(2, 'left')]}
      selectedNoteId={selected()} totalCount={2} onSelect={(note) => setSelected(note.noteId)} onLoadMore={async () => {}} /></>
  }, async () => new Blob(['image'], { type: 'image/png' }))
  try {
    await settle()
    expect(harness.host.querySelector('.document-reader-footer')?.textContent).toContain('Page 1 / 2')
    expect(harness.host.querySelector('.document-reader-toolbar')?.textContent).not.toContain('Page 1 / 2')
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', cancelable: true }))
    await settle()
    expect(harness.host.querySelector('.document-reader-footer')?.textContent).toContain('Page 2 / 2')
    const input = harness.host.querySelector('input')!
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }))
    await settle()
    expect(harness.host.textContent).toContain('Page 2 / 2')
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', cancelable: true }))
    await settle()
    expect(harness.host.textContent).toContain('Page 1 / 2')
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', ctrlKey: true, cancelable: true }))
    await settle()
    expect(harness.host.textContent).toContain('Page 2 / 2')
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'u', ctrlKey: true, cancelable: true }))
    await settle()
    expect(harness.host.textContent).toContain('Page 1 / 2')
  } finally { harness.close() }
})


test('PDF translations stay plain text and page navigation selects source notes without retaining another page translation', async () => {
  const sourcePages = [page(1, 'left'), page(2, 'left')].map((note) => ({ ...note,
    metaJSON: JSON.stringify({ documentPage: { pageNumber: note.noteNumber, originFileId: 'file-pdf',
      originMediaType: 'application/pdf', ocrState: 'complete', analysis: { binding: 'left' } } }),
  }))
  const selected: string[] = []
  const requests: string[] = []
  const openTranslation = vi.fn()
  const translatedText = '# Plain heading\n\n![not an image](/files/translation-image) <b>plain</b>'
  const harness = mount(() => {
    const [selectedId, setSelectedId] = createSignal(noteId('note-1'))
    return <DocumentNotebookReader notes={sourcePages} selectedNoteId={selectedId()} displayMode="translation"
      translatedVersion={{ noteId: 'note-1', targetLanguage: 'en', text: translatedText }}
      onOpenTranslation={openTranslation} totalCount={2} onSelect={(note) => {
        selected.push(note.noteId); setSelectedId(note.noteId)
      }} onLoadMore={async () => {}} />
  }, async (id) => { requests.push(id); return new Blob(['pdf'], { type: 'application/pdf' }) })
  try {
    await settle()
    const translation = harness.host.querySelector('[aria-label="Translated page"]')!
    expect(translation.querySelector('pre')?.textContent).toBe(translatedText)
    expect(translation.querySelector('pre')?.getAttribute('lang')).toBe('en')
    expect(translation.querySelector('img, h1, b')).toBeNull()
    expect(requests).toEqual(['file-pdf'])
    harness.button('Next page').click()
    await settle()
    expect(selected).toEqual(['note-2'])
    expect(harness.host.querySelector('[data-note-id]')?.getAttribute('data-note-id')).toBe('note-2')
    expect(harness.host.textContent).toContain('Page 2 / 2')
    expect(harness.host.textContent).toContain('No translation for this page yet')
    expect(harness.host.textContent).not.toContain(translatedText)
    expect(harness.host.querySelector('[aria-label="Translated page"] pre')).toBeNull()
    harness.button('Translate page').click()
    expect(openTranslation).toHaveBeenCalledTimes(1)
    expect(requests).toEqual(['file-pdf'])
    harness.button('Previous page').click()
    await settle()
    expect(selected).toEqual(['note-2', 'note-1'])
    expect(harness.host.querySelector('[aria-label="Translated page"] pre')?.textContent).toBe(translatedText)
  } finally { harness.close() }
})
