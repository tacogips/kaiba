import { createSignal, type JSX } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId, type FileId } from '../notes/ids'
import type { Note } from '../notes/types'
import { DocumentNotebookReader } from './DocumentNotebookReader'
import { MarkdownBody } from './Markdown'

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
    expect(harness.host.textContent).toContain('Text on this page is not searchable yet.')
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

test('manual page OCR reports failure, allows retry, and keeps OCR text hidden', async () => {
  let calls = 0
  const harness = mount(() => {
    const [notes, setNotes] = createSignal([page(2)])
    return <DocumentNotebookReader notes={notes()} selectedNoteId={noteId('note-2')} totalCount={1}
      onSelect={() => {}} onLoadMore={async () => {}} onRecognize={async (note) => {
        calls += 1
        expect(note.noteId).toBe('note-2')
        if (calls === 1) throw new Error('OCR temporarily unavailable')
        const metadata = JSON.parse(note.metaJSON!)
        metadata.documentPage.ocrState = 'complete'
        setNotes([{ ...note, bodyMarkdown: 'Recognized page text', metaJSON: JSON.stringify(metadata) }])
      }} />
  }, async () => new Blob(['image'], { type: 'image/png' }))
  try {
    await settle()
    expect(harness.host.textContent).toContain('Text on this page is not searchable yet.')
    expect(harness.host.querySelector('img')?.alt).toBe('Original page 2')
    harness.button('Make page searchable').click()
    expect(harness.host.textContent).toContain('Making page searchable...')
    await settle()
    expect(harness.host.textContent).toContain('OCR temporarily unavailable')
    harness.button('Make page searchable').click()
    await settle()
    expect(calls).toBe(2)
    expect(harness.host.textContent).not.toContain('Recognized page text')
    expect(harness.host.textContent).not.toContain('Text on this page is not searchable yet.')
    expect(harness.button('Make page searchable')).toBeUndefined()
    expect(harness.host.querySelector('img')?.alt).toBe('Original page 2')
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
