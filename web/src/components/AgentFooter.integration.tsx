import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { AgentFooter } from './AgentFooter'

test('footer expands and sends an unscoped question into the right-pane conversation', async () => {
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
    host.querySelector<HTMLButtonElement>('[aria-label="Ask AI"]')!.click()
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
