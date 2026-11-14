import { render } from 'solid-js/web'
import { expect, test } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { Note, Notebook } from '../notes/types'
import { noteId, notebookId } from '../notes/ids'
import { ChatbookView } from '../views/ChatbookView'

async function settle() { for (let i = 0; i < 6; i++) await new Promise((resolve) => setTimeout(resolve, 0)) }
function press(target: Element, key: string, init: KeyboardEventInit = {}) {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init })
  target.dispatchEvent(event)
  return event
}

test('global writing and pane chords focus the actual notebook buffer and preserve its current-note insertion point', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const book: Notebook = { notebookId: notebookId('keyboard-book'), title: 'Keyboard notebook', type: 'DOCUMENT', readOnly: false,
    createdAt: '', updatedAt: '', tags: [], noteCount: 2 }
  const conversation: Notebook = { ...book, notebookId: notebookId('saved-chat'), title: 'Ongoing conversation', type: 'AGENT_CHAT', noteCount: 0 }
  const notes: Note[] = ['First', 'Second'].map((title, index) => ({ noteId: noteId(`keyboard-${index + 1}`), notebookId: book.notebookId,
    noteNumber: index + 1, title, bodyMarkdown: `# ${title}\n\nBody ${index + 1}`, readOnly: false, createdAt: '', updatedAt: '', tags: [] }))
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [book, conversation], notebook: async () => book,
    notes: async (id: string) => id === conversation.notebookId ? [] : notes, note: async (id: string) => notes.find((note) => note.noteId === id), noteFiles: async () => [],
    noteComments: async () => [], notebookComments: async () => [], noteConversations: async () => [], notebookConversations: async () => [],
    agentModels: async () => ({ models: [], providers: [], configuredModel: '' }), saveNotebookDraft: async () => book,
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client: api, router: {
    currentHash: () => '#/note/keyboard-2', setHash: () => {}, addListener: () => {}, removeListener: () => {},
  } }}><ChatbookView /></AppStoreProvider>, host)
  try {
    await settle()
    const details = host.querySelector<HTMLButtonElement>('.pane-right button')!
    details.focus(); expect(press(details, 'i').defaultPrevented).toBe(true); await settle()
    const source = host.querySelector<HTMLTextAreaElement>('.notebook-source')!
    expect(source).not.toBeNull(); expect(document.activeElement).toBe(source)
    expect(source.dataset.vimMode).toBe('insert')
    const second = source.value.indexOf('# Second')
    expect(source.selectionStart).toBe(second)
    const chord = async (key: string) => {
      const active = document.activeElement!
      expect(press(active, 'w', { ctrlKey: true, code: 'KeyW' }).defaultPrevented).toBe(true)
      expect(press(active, key).defaultPrevented).toBe(true)
      await settle()
    }
    await chord('l'); expect(document.activeElement?.closest('.pane-right')).not.toBeNull()
    press(document.activeElement!, 'i'); await settle()
    expect(document.activeElement).toBe(source); expect(source.dataset.vimMode).toBe('insert')
    expect(source.selectionStart).toBe(second)
    await chord('h'); expect(document.activeElement?.closest('.pane-left')).not.toBeNull()
    await chord('j'); expect(document.activeElement).toBe(host.querySelector('.agent-footer textarea'))
    host.querySelector<HTMLButtonElement>('.agent-footer [aria-label="AI conversations"]')!.click(); await settle()
    host.querySelector<HTMLButtonElement>('.footer-history-entry')!.click(); await settle()
    expect(host.querySelector('.footer-context-label')?.textContent).toBe('Saved conversation: Ongoing conversation')
    const chatInput = host.querySelector<HTMLTextAreaElement>('.agent-footer textarea')!
    chatInput.value = 'Keep this draft'; chatInput.dispatchEvent(new Event('input', { bubbles: true })); chatInput.focus()
    await chord('h'); await chord('j')
    expect(host.querySelector('.footer-context-label')?.textContent).toBe('Saved conversation: Ongoing conversation')
    expect(host.querySelector<HTMLTextAreaElement>('.agent-footer textarea')!.value).toBe('Keep this draft')
    await chord('k'); expect(document.activeElement).toBe(source)
    await chord('w'); expect(document.activeElement?.closest('.pane-right')).not.toBeNull()
    expect(source.value).toBe('# First\n\nBody 1\n\n<><>\n\n# Second\n\nBody 2')
  } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
})
