import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { AgentFooter } from './AgentFooter'

test('footer expands and opens the saved conversation for an unscoped question', async () => {
  const send = vi.fn().mockRejectedValueOnce(new Error('Lost response'))
    .mockResolvedValue({ conversationNotebookId: 'chat-1' })
  const open = vi.fn()
  const client = {
    initialize: async () => {}, appSetting: async () => undefined, setAppSetting: async () => {},
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [],
    sendAgentChatMessage: send, streamHeaders: () => ({}),
    agentModels: async () => ({ models: [{ modelId: 'small' }, { modelId: 'large' }], configuredModel: 'small', providers: ['codex'], configuredProvider: 'codex' }),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client }}><AgentFooter onConversation={open} /></AppStoreProvider>, host)
  try {
    expect(host.querySelector('textarea')).toBeNull()
    const launcher = host.querySelector<HTMLButtonElement>('[aria-label="Ask AI"]')!
    expect(launcher.title).toContain('Saved conversations are available')
    launcher.click()
    expect(host.querySelector('[aria-label="Close AI composer"]')?.getAttribute('aria-expanded')).toBe('true')
    await vi.waitFor(() => expect(host.querySelector<HTMLSelectElement>('[aria-label="Agent model"]')?.value).toBe('small'))
    const model = host.querySelector<HTMLSelectElement>('[aria-label="Agent model"]')!
    model.value = 'large'
    model.dispatchEvent(new Event('input', { bubbles: true }))
    const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
    Object.defineProperty(picker, 'files', { configurable: true, value: [new File(['context'], 'context.txt', { type: 'text/plain' })] })
    picker.dispatchEvent(new Event('change', { bubbles: true }))
    await vi.waitFor(() => expect(host.querySelector('.attachment-card')?.textContent).toContain('context.txt'))
    const input = host.querySelector('textarea')!
    input.value = 'Explain spaced repetition'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    const submit = () => host.querySelector('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    submit()
    await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain('Lost response'))
    submit()
    await vi.waitFor(() => expect(open).toHaveBeenCalledWith('chat-1'))
    expect(send.mock.calls[0]).toEqual(send.mock.calls[1])
    expect(send.mock.calls[0]![0]).toEqual({
      userMarkdown: 'Explain spaced repetition', idempotencyKey: expect.any(String), model: 'large', provider: 'codex',
      attachments: [{ originalFilename: 'context.txt', mediaType: 'text/plain', contentBase64: btoa('context') }],
    })
    expect(host.querySelector('textarea')).toBeNull()
  } finally { dispose(); host.remove() }
})

test.each(['note', 'notebook'] as const)('footer sends the selected %s as AI context', async (selection) => {
  const note = { noteId: 'page-3', notebookId: 'document', noteNumber: 3, title: 'Selected page',
    bodyMarkdown: 'Page content', readOnly: true, createdAt: '', updatedAt: '', tags: [] }
  const notebook = { notebookId: 'document', title: 'Imported paper', type: 'DOCUMENT',
    readOnly: true, createdAt: '', updatedAt: '', tags: [] }
  const savedConversation = { ...notebook, notebookId: 'saved-chat', title: 'Earlier discussion', type: 'AGENT_CHAT' }
  const navigate = vi.fn()
  const send = vi.fn().mockResolvedValue({ conversationNotebookId: 'conversation', agentStatus: 'answered' })
  const client = {
    initialize: async () => {}, appSetting: async () => undefined, setAppSetting: async () => {},
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [notebook, savedConversation],
    notebook: async () => notebook, note: async () => note, notes: async (id: string) => id === 'saved-chat' ? [] : [note],
    noteComments: async () => [], notebookComments: async () => [],
    noteConversations: async () => [], notebookConversations: async () => [],
    sendAgentChatMessage: send, streamHeaders: () => ({}),
    agentModels: async () => ({ models: [], providers: [] }),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => <AppStoreProvider options={{ client, router: {
    currentHash: () => selection === 'note' ? '#/note/page-3' : '#/notebook/document',
    setHash: navigate, addListener: () => {}, removeListener: () => {},
  } }}><AgentFooter onConversation={() => {}} /></AppStoreProvider>, host)
  try {
    await vi.waitFor(() => {
      host.querySelector<HTMLButtonElement>('[aria-label="Ask AI"]')?.click()
      expect(host.querySelector('.footer-context-label')?.textContent).toContain('Imported paper')
    })
    if (selection === 'note') expect(host.querySelector('.footer-context-label')?.textContent).toContain('Page 3')
    const input = host.querySelector('textarea')!
    input.value = 'Explain this material'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
    await vi.waitFor(() => expect(send).toHaveBeenCalled())
    const request = send.mock.calls[0]![0]
    expect(request.userMarkdown).toBe('Explain this material')
    expect(request.subjectNoteId).toBe(selection === 'note' ? 'page-3' : undefined)
    expect(request.subjectNotebookId).toBe(selection === 'notebook' ? 'document' : undefined)
    if (selection === 'note') {
      await vi.waitFor(() => expect(host.querySelector('textarea')?.value).toBe(''))
      input.value = 'Keep this page draft'
      input.dispatchEvent(new Event('input', { bubbles: true }))
      host.querySelector<HTMLButtonElement>('[aria-label="AI conversations"]')!.click()
      const saved = [...host.querySelectorAll<HTMLButtonElement>('.footer-history-entry')].find((button) => button.textContent === 'Earlier discussion')!
      saved.click()
      await vi.waitFor(() => expect(host.querySelector('.footer-context-label')?.textContent).toContain('Saved conversation: Earlier discussion'))
      const continuation = host.querySelector('textarea')!
      continuation.value = 'Continue this discussion'
      continuation.dispatchEvent(new Event('input', { bubbles: true }))
      continuation.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(2))
      expect(send.mock.calls[1]![0].conversationNotebookId).toBe('saved-chat')
      expect(send.mock.calls[1]![0].subjectNoteId).toBeUndefined()
      expect(navigate).not.toHaveBeenCalled()
      host.querySelector<HTMLButtonElement>('[aria-label="Return to current page discussion"]')!.click()
      await vi.waitFor(() => expect(host.querySelector('textarea')?.value).toBe('Keep this page draft'))
      expect(host.querySelector('.footer-context-label')?.textContent).toContain('Imported paper · Page 3')
    }
  } finally { dispose(); host.remove() }
})
