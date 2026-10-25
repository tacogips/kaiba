import type { JSX } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import { ChatbookView } from './ChatbookView'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId } from '../notes/ids'
import { testDocumentPage } from '../notes/documentPageFixtures'

vi.mock('../notes/events', () => ({ subscribeNoteEvents: () => () => undefined }))
vi.mock('../components/PDFDocumentView', () => ({ PDFDocumentView: (props: { textView?: JSX.Element }) => <div>{props.textView ?? 'Original PDF'}</div> }))

test('opening Tasks and jumping back restores the page and OCR display mode in the real workspace shell', async () => {
  let hash = '#/note/page-1'; const listeners = new Set<() => void>()
  const router = { currentHash: () => hash, setHash: (value: string) => { hash = value; listeners.forEach((listener) => listener()) },
    addListener: (listener: () => void) => { listeners.add(listener) }, removeListener: (listener: () => void) => { listeners.delete(listener) } }
  const note = { noteId: noteId('page-1'), notebookId: notebookId('pdf'), noteNumber: 1, title: 'Page 1', bodyMarkdown: '', readOnly: false,
    createdAt: '', updatedAt: '', tags: [], documentPage: testDocumentPage({ originMediaType: 'application/pdf', textStatus: 'complete' }) }
  const book = { notebookId: notebookId('pdf'), type: 'DOCUMENT', title: 'PDF', readOnly: true, tags: [], createdAt: '', updatedAt: '', noteCount: 1 }
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined, tags: async () => [], tagClasses: async () => [],
    notebooks: async () => [book], notebook: async () => book, notes: async () => [note], note: async () => note, noteTranslations: async () => [],
    documentPageText: async () => ({ pageNumber: 1, text: 'OCR page content', textSource: 'ocr', textStatus: 'complete' }),
    agentModels: async () => ({ models: [], configuredModel: '' }),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router, paneStorage: { getItem: () => null, setItem: () => {} } }}><ChatbookView /></AppStoreProvider>, host)
  try {
    await vi.waitFor(() => expect(host.querySelector('.document-version-switch')).not.toBeNull())
    Array.from(host.querySelectorAll<HTMLButtonElement>('.document-version-switch button')).find((button) => button.textContent === 'OCR')!.click()
    await vi.waitFor(() => expect(host.querySelector('.pdf-text-stage pre')?.textContent).toBe('OCR page content'))
    host.querySelector<HTMLAnchorElement>('.workspace-task-link')!.click()
    expect(hash).toBe('#/tasks')
    host.querySelector<HTMLButtonElement>('[aria-label="Jump back"]')!.click()
    expect(hash).toBe('#/note/page-1')
    await vi.waitFor(() => expect(host.querySelector('.pdf-text-stage pre')?.textContent).toBe('OCR page content'))
    expect(Array.from(host.querySelectorAll('.document-version-switch button')).find((button) => button.textContent === 'OCR')?.getAttribute('aria-pressed')).toBe('true')
  } finally { dispose(); host.remove() }
})

test('reload protection covers queued and running OCR and clears once work finishes', async () => {
  const note = { noteId: noteId('page-1'), notebookId: notebookId('pdf'), noteNumber: 1, title: 'Page 1', bodyMarkdown: '', readOnly: false,
    createdAt: '', updatedAt: '', tags: [], documentPage: testDocumentPage({ textStatus: 'pending' }) }
  let finish!: (value: typeof note) => void
  const recognize = vi.fn(() => new Promise<typeof note>((resolve) => { finish = resolve }))
  const api = { initialize: async () => {}, appSetting: async () => undefined, tags: async () => [], tagClasses: async () => [],
    notebooks: async () => [], note: async () => note, recognizeDocumentPage: recognize,
  } as unknown as NoteGraphQLClient
  const router = { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} }
  let app!: AppStore
  function Workspace() { app = useApp(); return <ChatbookView /> }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router, paneStorage: { getItem: () => null, setItem: () => {} } }}><Workspace /></AppStoreProvider>, host)
  const unloadBlocked = () => { const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event); return event.defaultPrevented }
  try {
    expect(unloadBlocked()).toBe(false)
    app.ocrTasks.enqueue(note.noteId)
    expect(unloadBlocked()).toBe(true)
    await vi.waitFor(() => expect(recognize).toHaveBeenCalledTimes(1))
    expect(unloadBlocked()).toBe(true)
    finish({ ...note, documentPage: { ...note.documentPage, textStatus: 'complete' } })
    await vi.waitFor(() => expect(app.ocrTasks.active()).toHaveLength(0))
    expect(unloadBlocked()).toBe(false)
  } finally { dispose(); host.remove() }
})

test('reload protection covers the settings debounce, save failure, and retry acknowledgment', async () => {
  let finish!: () => void
  const save = vi.fn().mockRejectedValueOnce(new Error('Offline')).mockImplementationOnce(() => new Promise<void>((resolve) => { finish = resolve }))
  const api = { initialize: async () => {}, appSetting: async () => undefined, tags: async () => [], tagClasses: async () => [],
    notebooks: async () => [], setAppSetting: save,
  } as unknown as NoteGraphQLClient
  const router = { currentHash: () => '#/', setHash: () => {}, addListener: () => {}, removeListener: () => {} }
  let app!: AppStore
  function Workspace() { app = useApp(); return <ChatbookView /> }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router, paneStorage: { getItem: () => null, setItem: () => {} } }}><Workspace /></AppStoreProvider>, host)
  const blocked = () => { const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event); return event.defaultPrevented }
  try {
    expect(blocked()).toBe(false)
    app.updateSettings({ pdfTextMode: 'ocr-only' })
    expect(blocked()).toBe(true)
    await vi.waitFor(() => expect(app.settingsSave.status()).toBe('error'))
    expect(app.state.settings.pdfTextMode).toBe('ocr-only')
    expect(blocked()).toBe(true)
    app.settingsSave.retry()
    expect(blocked()).toBe(true)
    finish(); await vi.waitFor(() => expect(app.settingsSave.status()).toBe('saved'))
    expect(blocked()).toBe(false)
    expect(JSON.parse(save.mock.calls[1]![1])).toMatchObject({ pdfTextMode: 'ocr-only' })
  } finally { dispose(); host.remove() }
})
