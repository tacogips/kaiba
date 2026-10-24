import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import { noteId, notebookId, tagId } from '../notes/ids'
import type { RouterEnvironment } from '../router'
import { JumpBackControl } from '../components/JumpBackControl'
import { AppStoreProvider, useApp, type AppStore } from './appStore'

vi.mock('../notes/events', () => ({ subscribeNoteEvents: () => () => undefined }))

function mount(initial = '#/note/page-0') {
  let hash = initial
  const listeners = new Set<() => void>()
  const router: RouterEnvironment = {
    currentHash: () => hash,
    setHash: (next) => { hash = next; for (const listener of listeners) listener() },
    addListener: (listener) => { listeners.add(listener) },
    removeListener: (listener) => { listeners.delete(listener) },
  }
  const notebook = { notebookId: notebookId('book'), title: 'Source', createdAt: '', updatedAt: '', readOnly: false }
  const client = {
    initialize: async () => undefined,
    appSetting: async () => undefined,
    searchEngineCapability: async () => false,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [notebook],
    notebook: async (id: string) => ({ ...notebook, notebookId: id }),
    notes: async () => [],
    note: async (id: string) => ({ noteId: id, notebookId: notebook.notebookId, noteNumber: 1,
      title: id, bodyMarkdown: '', readOnly: false, createdAt: '', updatedAt: '' }),
  } as unknown as NoteGraphQLClient
  let app!: AppStore
  function Capture() { app = useApp(); return <JumpBackControl /> }
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client, router, paneStorage: { getItem: () => null, setItem: () => undefined } }}>
    <Capture />
  </AppStoreProvider>, host)
  return { app, host, router, hash: () => hash, close: () => { dispose(); host.remove() } }
}

describe('central reader jump history', () => {
  test('records ordinary note/page selections and restores without reverse entries', () => {
    const view = mount()
    try {
      const back = view.host.querySelector<HTMLButtonElement>('[aria-label="Jump back"]')!
      expect(back.disabled).toBe(true)
      view.app.openNote(noteId('page-1'), notebookId('book'))
      view.app.openNote(noteId('page-1'))
      view.app.openNote(noteId('page-2'))
      expect(view.app.state.returnStack).toEqual(['#/note/page-0', '#/note/page-1'])
      expect(back.disabled).toBe(false)
      back.click()
      expect(view.hash()).toBe('#/note/page-1')
      expect(view.app.state.returnStack).toEqual(['#/note/page-0'])
      back.click()
      expect(view.hash()).toBe('#/note/page-0')
      expect(view.app.state.returnStack).toEqual([])
      expect(back.disabled).toBe(true)
      view.app.goBack()
      expect(view.hash()).toBe('#/note/page-0')
    } finally { view.close() }
  })

  test('ignores settings/search and same-source pane changes while restoring their reader context', () => {
    const view = mount()
    try {
      view.app.openConfig()
      view.app.openReader()
      view.app.openSearch('word', 'all', 'grep')
      view.app.openReader()
      view.app.openConversation(notebookId('conversation'))
      view.app.openTagPane(tagId('subject'))
      expect(view.app.state.returnStack).toEqual([])
      view.app.openNoteWithReturn(noteId('linked'))
      expect(view.app.state.returnStack).toEqual(['#/note/page-0?conv=conversation&tag=subject'])
      view.app.goBack()
      expect(view.hash()).toBe('#/note/page-0?conv=conversation&tag=subject')
      expect(view.app.state.returnStack).toEqual([])
      view.app.openConfig()
      view.app.openNote(noteId('search-result'))
      expect(view.app.state.returnStack).toEqual(['#/note/page-0?conv=conversation&tag=subject'])
    } finally { view.close() }
  })

  test('captures direct routes, notebook selection, deselection and home without stacking the empty view', async () => {
    const view = mount()
    try {
      await vi.waitFor(() => expect(view.app.state.notebookId).toBe('book'))
      view.app.deselectNote()
      expect(view.app.state.returnStack).toEqual(['#/note/page-0'])
      view.router.setHash('#/note/direct')
      view.app.openNotebook(notebookId('other'))
      view.app.openHome()
      view.app.openNote(noteId('after-home'))
      expect(view.app.state.returnStack).toEqual(['#/note/page-0', '#/notebook/book', '#/note/direct', '#/notebook/other'])
      view.app.goBack()
      expect(view.hash()).toBe('#/notebook/other')
      expect(view.app.state.returnStack).toHaveLength(3)
    } finally { view.close() }
  })

  test('keeps the newest 500 entries', () => {
    const view = mount()
    try {
      for (let page = 1; page <= 505; page += 1) view.app.openNote(noteId(`page-${page}`))
      expect(view.app.state.returnStack).toHaveLength(500)
      expect(view.app.state.returnStack[0]).toBe('#/note/page-5')
      expect(view.app.state.returnStack[499]).toBe('#/note/page-504')
      view.app.goBack()
      expect(view.hash()).toBe('#/note/page-504')
      expect(view.app.state.returnStack).toHaveLength(499)
    } finally { view.close() }
  })

  test('retains explicit tag returns and skips no-move jump entries', () => {
    const view = mount()
    try {
      view.app.openNoteWithReturn(noteId('page-0'))
      view.app.openTagPaneWithReturn(tagId('a'))
      view.app.openTagPaneWithReturn(tagId('b'))
      view.app.goBack()
      expect(view.hash()).toBe('#/note/page-0?tag=a')
      view.app.goBack()
      expect(view.hash()).toBe('#/note/page-0')
      view.app.goBack()
      expect(view.app.state.returnStack).toEqual([])
    } finally { view.close() }
  })
})
