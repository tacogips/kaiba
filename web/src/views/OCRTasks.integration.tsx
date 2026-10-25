import { Show } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { testDocumentPage } from '../notes/documentPageFixtures'
import type { RouterEnvironment } from '../router'
import { DocumentPageTextView } from '../components/DocumentPageTextView'
import { TaskIndicator } from '../components/TaskIndicator'
import { TasksView } from './TasksView'

vi.mock('../notes/events', () => ({ subscribeNoteEvents: () => () => undefined }))

test('inline OCR queues work, header summarizes active tasks, task navigation returns to the page and text refreshes', async () => {
  let hash = '#/note/page-1'; const listeners = new Set<() => void>()
  const router: RouterEnvironment = { currentHash: () => hash, setHash: (next) => { hash = next; listeners.forEach((listener) => listener()) },
    addListener: (listener) => { listeners.add(listener) }, removeListener: (listener) => { listeners.delete(listener) } }
  const completed = new Set<string>(); const finishes = new Map<string, () => void>()
  const page = (id: string): Note => ({ noteId: noteId(id), notebookId: notebookId('pdf'), noteNumber: Number(id.slice(-1)), title: id,
    bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '', documentPage: testDocumentPage({ pageNumber: Number(id.slice(-1)), textStatus: completed.has(id) ? 'complete' : 'pending' }) })
  const book = { notebookId: notebookId('pdf'), title: 'Example PDF', type: 'DOCUMENT', readOnly: true, tags: [], createdAt: '', updatedAt: '' }
  const recognize = vi.fn((id: string) => new Promise<Note>((resolve) => { finishes.set(id, () => { completed.add(id); resolve(page(id)) }) }))
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined, tags: async () => [], tagClasses: async () => [],
    notebooks: async () => [book], notebook: async () => book, notes: async () => [page('page-1'), page('page-2'), page('page-3')], note: async (id: string) => page(id),
    recognizeDocumentPage: recognize, documentPageText: async (id: string) => ({ pageNumber: Number(id.slice(-1)), text: completed.has(id) ? `Recognized ${id}` : '', textStatus: completed.has(id) ? 'complete' : 'pending' }),
  } as unknown as NoteGraphQLClient
  let app!: AppStore
  function Workspace() {
    app = useApp()
    return <><TaskIndicator /><Show when={app.state.route.kind === 'tasks'} fallback={<DocumentPageTextView noteId={noteId('page-1')} />}><TasksView /></Show></>
  }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router, paneStorage: { getItem: () => null, setItem: () => {} } }}><Workspace /></AppStoreProvider>, host)
  try {
    await vi.waitFor(() => expect(host.textContent).toContain('No searchable text on this page yet.'))
    host.querySelector<HTMLButtonElement>('[aria-label="Make page searchable"]')!.click()
    await vi.waitFor(() => expect(recognize).toHaveBeenCalledWith('page-1', true))
    expect(host.querySelector<HTMLButtonElement>('[aria-label="Make page searchable"]')?.disabled).toBe(true)
    app.ocrTasks.enqueue(noteId('page-2'), 'Example PDF', 2)
    app.ocrTasks.enqueue(noteId('page-3'), 'Example PDF', 3)
    expect(host.querySelector('.workspace-task-link')?.textContent).toContain('2 more')
    host.querySelector<HTMLAnchorElement>('.workspace-task-link')!.click()
    expect(hash).toBe('#/tasks')
    expect(host.querySelectorAll('.task-row')).toHaveLength(3)
    expect(host.textContent).toContain('Running')
    expect(host.querySelector('.task-row .task-status')?.textContent).toBe('Running')
    host.querySelector<HTMLButtonElement>('[aria-label="Jump back"]')!.click()
    expect(hash).toBe('#/note/page-1')
    finishes.get('page-1')!()
    await vi.waitFor(() => expect(host.querySelector('pre')?.textContent).toBe('Recognized page-1'))
    await vi.waitFor(() => expect(recognize).toHaveBeenCalledWith('page-2', false))
    finishes.get('page-2')!()
    await vi.waitFor(() => expect(recognize).toHaveBeenCalledWith('page-3', false))
    finishes.get('page-3')!()
    await vi.waitFor(() => expect(app.ocrTasks.active()).toHaveLength(0))
    app.openTasks()
    expect(host.querySelectorAll('[data-status="completed"]')).toHaveLength(3)
    const openPage = Array.from(host.querySelectorAll('button')).find((button) => button.textContent === 'Open page')!
    openPage.click()
    expect(hash).toContain('#/note/')
    app.goBack(); expect(hash).toBe('#/tasks')
    app.goBack(); expect(hash).toBe('#/note/page-1')
  } finally { dispose(); host.remove() }
})
