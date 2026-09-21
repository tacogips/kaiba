import { describe, expect, test, vi } from 'vitest'
import { createComponent } from 'solid-js'
import { createStore } from 'solid-js/store'
import { render } from 'solid-js/web'
import { SourceAnalyses } from './SourceAnalyses'
import { notebookPageLimit } from '../notes/client'
import { noteId, notebookId } from '../notes/ids'
import type { Note } from '../notes/types'
import type { AppStore } from '../state/appStore'
import type { WebAppSettings } from '../notes/settings'

function source(index: number): Note {
  return { noteId: noteId(`note-${index}`), notebookId: notebookId('book'), noteNumber: index,
    title: `Source ${index}`, bodyMarkdown: `Text ${index}`, readOnly: true, createdAt: '', updatedAt: '' }
}

function fixture(pages: Note[][] = [[source(1), source(2)]]) {
  const [state, setState] = createStore({ settings: { fontScale: 1, agentProvider: 'test-provider', agentModel: 'test-model' } as WebAppSettings,
    noteId: source(1).noteId })
  const notes = vi.fn(async (_id: unknown, offset: number) => pages[offset === 0 ? 0 : 1] ?? [])
  const send = vi.fn(async () => ({ conversationNotebookId: notebookId('result'), turnNoteId: noteId('turn'), agentStatus: 'queued' }))
  const openNotebook = vi.fn()
  const app = { state, client: { notes, sendAgentChatMessage: send }, openNotebook,
    updateSettings: (partial: Partial<WebAppSettings>) => setState('settings', (current) => ({ ...current, ...partial })),
    refreshCatalog: vi.fn(async () => undefined),
  } as unknown as AppStore
  const container = document.createElement('div')
  document.body.append(container)
  const unmount = render(() => createComponent(SourceAnalyses, { app, notebookId: notebookId('book') }), container)
  const dispose = () => { unmount(); container.remove() }
  const button = (text: string) => [...container.querySelectorAll('button')].find((item) => item.textContent === text)!
  button('Analyses').click()
  return { container, dispose, button, notes, send, openNotebook, state, setState }
}

describe('SourceAnalyses', () => {
  test('keeps batch preferences fixed while another source is awaiting submission', async () => {
    const f = fixture()
    try {
      await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(2))
      let release!: () => void
      f.send.mockImplementationOnce(() => new Promise((resolve) => { release = () => resolve({ conversationNotebookId: notebookId('first-result'), turnNoteId: noteId('turn'), agentStatus: 'pending' }) }))
      f.button('Select all').click()
      f.button('Apply to selected notes').click()
      f.setState('settings', { fontScale: 1, agentProvider: 'changed', agentModel: 'changed' })
      release()
      await vi.waitFor(() => expect(f.send).toHaveBeenCalledTimes(2))
      expect(f.send.mock.calls[1]).toEqual([expect.objectContaining({ subjectNoteId: noteId('note-2'), model: 'test-model', provider: 'test-provider' })])
    } finally { f.dispose() }
  })

  test('rejects repeated pages and allows a clean source reload', async () => {
    const page = Array.from({ length: notebookPageLimit }, (_, index) => source(index + 1))
    const f = fixture([page, page])
    try {
      await vi.waitFor(() => expect(f.container.textContent).toContain('source list changed'))
      expect(f.notes).toHaveBeenCalledTimes(2)
      expect(f.button('Apply to selected notes').disabled).toBe(true)
      f.notes.mockResolvedValue([source(1)])
      f.button('Reload sources').click()
      await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(1))
      expect(f.container.querySelector('[role="alert"]')).toBeNull()
    } finally { f.dispose() }
  })

  test('loads all pages, scopes each submission and exposes durable result links', async () => {
    const f = fixture([Array.from({ length: notebookPageLimit }, (_, index) => source(index + 1)), [source(notebookPageLimit + 1)]])
    try {
      await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(notebookPageLimit + 1))
      expect(f.notes.mock.calls).toEqual([[notebookId('book'), 0], [notebookId('book'), notebookPageLimit]])
      f.button('Apply to selected notes').click()
      await vi.waitFor(() => expect(f.button('Open result')).toBeDefined())
      expect(f.send).toHaveBeenCalledTimes(1)
      expect(f.send.mock.calls[0]).toEqual([expect.objectContaining({ subjectNoteId: noteId('note-1'), model: 'test-model', provider: 'test-provider' })])
      expect(f.send.mock.calls[0]).toEqual([expect.not.objectContaining({ mode: 'edit' })])
      expect(f.container.textContent).toContain('Submitted — open the result to follow progress')
      f.button('Open result').click()
      expect(f.openNotebook).toHaveBeenCalledWith(notebookId('result'))
    } finally { f.dispose() }
  })

  test('retains successful rows after another source fails, without automatic replay', async () => {
    const f = fixture()
    try {
      await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(2))
      f.send.mockRejectedValueOnce(new Error('Connection lost'))
      f.button('Select all').click()
      f.button('Apply to selected notes').click()
      await vi.waitFor(() => expect(f.button('Open result')).toBeDefined())
      expect(f.send).toHaveBeenCalledTimes(2)
      expect(f.container.textContent).toContain('Submission not confirmed: Connection lost')
      expect(f.container.textContent).toContain('Check source discussions')
    } finally { f.dispose() }
  })

  test('stops submitting further sources when the panel is disposed', async () => {
    const f = fixture()
    await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(2))
    let release!: () => void
    f.send.mockImplementationOnce(() => new Promise((resolve) => { release = () => resolve({ conversationNotebookId: notebookId('result'), turnNoteId: noteId('turn'), agentStatus: 'queued' }) }))
    f.button('Select all').click()
    f.button('Apply to selected notes').click()
    expect(f.send).toHaveBeenCalledTimes(1)
    f.dispose()
    release()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(f.send).toHaveBeenCalledTimes(1)
  })

  test('saves and removes reusable custom templates', async () => {
    const f = fixture()
    try {
      await vi.waitFor(() => expect(f.container.querySelectorAll('input[type="checkbox"]').length).toBe(2))
      const select = f.container.querySelector('select')!
      select.value = 'custom'
      select.dispatchEvent(new Event('change', { bubbles: true }))
      const name = f.container.querySelector<HTMLInputElement>('[aria-label="Template name"]')!
      name.value = 'Methods'; name.dispatchEvent(new Event('input', { bubbles: true }))
      const prompt = f.container.querySelector('textarea')!
      prompt.value = 'Explain the methods.'; prompt.dispatchEvent(new Event('input', { bubbles: true }))
      f.button('Save template').click()
      expect(f.state.settings.analysisTemplates).toEqual([expect.objectContaining({ name: 'Methods', prompt: 'Explain the methods.' })])
      f.button('Apply to selected notes').click()
      await vi.waitFor(() => expect(f.button('Open result')).toBeDefined())
      expect(f.send.mock.calls[0]).toEqual([expect.objectContaining({ userMarkdown: expect.stringContaining('# Analysis: Methods') })])
      f.button('Remove template').click()
      expect(f.state.settings.analysisTemplates).toEqual([])
    } finally { f.dispose() }
  })

  test('rejects a custom template that would exceed the settings storage budget', async () => {
    const f = fixture()
    try {
      const saved = Array.from({ length: 6 }, (_, index) => ({ id: `custom-${index}`, name: 'Long', prompt: 'x'.repeat(10000) }))
      f.setState('settings', 'analysisTemplates', saved)
      const select = f.container.querySelector('select')!
      select.value = 'custom'; select.dispatchEvent(new Event('change', { bubbles: true }))
      const name = f.container.querySelector<HTMLInputElement>('[aria-label="Template name"]')!
      name.value = 'Extra'; name.dispatchEvent(new Event('input', { bubbles: true }))
      const prompt = f.container.querySelector('textarea')!
      prompt.value = 'y'.repeat(10000); prompt.dispatchEvent(new Event('input', { bubbles: true }))
      f.button('Save template').click()
      expect(f.container.textContent).toContain('Saved templates are full')
      expect(f.state.settings.analysisTemplates).toHaveLength(6)
    } finally { f.dispose() }
  })
})
