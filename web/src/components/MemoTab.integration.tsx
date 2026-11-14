import { noteId as asNoteId, notebookId as asNotebookId } from '../notes/ids'
import { render } from 'solid-js/web'
import { describe, expect, test } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import type { WebAppSettings } from '../notes/settings'
import type { AgentChatAttachmentInput, AgentChatMessageResult, Note } from '../notes/types'
import type { AppStore } from '../state/appStore'
import { MemoTab } from './MemoTab'
import type { NotebookId } from '../notes/ids'

const subject: Note = {
  noteId: asNoteId('subject-1'), notebookId: asNotebookId('notebook-1'), noteNumber: 1, title: 'Subject', bodyMarkdown: '# Subject',
  readOnly: false, createdAt: '2026-08-13T00:00:00Z', updatedAt: '2026-08-13T00:00:00Z',
}
const earlierTurn: Note = {
  noteId: asNoteId('turn-old'), notebookId: asNotebookId('conversation-old'), noteNumber: 1, title: 'Earlier question',
  bodyMarkdown: '## User\nEarlier question\n## Agent\nEarlier answer', readOnly: false,
  createdAt: '2026-08-13T00:01:00Z', updatedAt: '2026-08-13T00:01:00Z',
  metaJSON: JSON.stringify({ kaibaChat: { status: 'answered', userMarkdown: 'Earlier question' } }),
}
const newTurn: Note = {
  noteId: asNoteId('turn-new'), notebookId: asNotebookId('conversation-new'), noteNumber: 1, title: 'New question',
  bodyMarkdown: '## User\nAsk in a new chat\n## Agent\nNew answer', readOnly: false,
  createdAt: '2026-08-13T00:02:00Z', updatedAt: '2026-08-13T00:02:00Z',
  metaJSON: JSON.stringify({ kaibaChat: { status: 'answered', userMarkdown: 'Ask in a new chat' } }),
}

async function settle(): Promise<void> {
  await Promise.resolve()
  await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  await Promise.resolve()
}

async function waitFor(expectation: () => void): Promise<void> {
  let failure: unknown
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      expectation()
      return
    } catch (error) {
      failure = error
      await settle()
    }
  }
  throw failure
}

function testStore(requests: Array<Record<string, unknown>>, memoWrites: string[]): AppStore {
  let newConversationCreated = false
  const state = {
    noteId: subject.noteId,
    notebookId: subject.notebookId,
    note: subject,
    settings: { agentModel: 'configured', fontScale: 1 },
    notebookRevisions: {},
    catalogRevision: 0,
  }
  const client = {
    agentModels: async () => ({
      models: [
        { modelId: 'configured', displayName: 'Configured model' },
        { modelId: 'compact', displayName: 'Compact model' },
      ],
      configuredModel: 'configured',
      discoveryAvailable: true,
    }),
    noteComments: async () => [],
    noteConversations: async () => [
      {
        notebookId: asNotebookId('conversation-old'), title: 'Earlier conversation', updatedAt: '2026-08-13T00:01:00Z',
        turnCount: 1, subjectNoteId: subject.noteId,
      },
      ...(newConversationCreated ? [{
        notebookId: asNotebookId('conversation-new'), title: 'New conversation', updatedAt: '2026-08-13T00:02:00Z',
        turnCount: 1, subjectNoteId: subject.noteId,
      }] : []),
    ],
    notes: async (notebookId: NotebookId) => notebookId === 'conversation-new' ? [newTurn] : [earlierTurn],
    sendAgentChatMessage: async (request: Record<string, unknown>): Promise<AgentChatMessageResult> => {
      requests.push(request)
      newConversationCreated = true
      return { conversationNotebookId: asNotebookId('conversation-new'), turnNoteId: null, agentStatus: 'answered' }
    },
    addNoteComment: async (_noteId: string, body: string) => { memoWrites.push(body) },
  } as unknown as NoteGraphQLClient
  return {
    state,
    client,
    notes: () => [subject],
    notebook: () => ({ notebookId: subject.notebookId, title: 'Notebook', readOnly: false }),
    updateSettings: (partial: Partial<WebAppSettings>) => Object.assign(state.settings, partial),
  } as unknown as AppStore
}

describe('MemoTab integration', () => {
  test('wires keyboard, controls, New chat history, and requests through the actual pane', async () => {
    const requests: Array<Record<string, unknown>> = []
    const memoWrites: string[] = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={testStore(requests, memoWrites)} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const composer = host.querySelector('textarea')
      const attachmentPicker = host.querySelector<HTMLInputElement>('input[type="file"]')
      const attachmentButton = host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')
      const memoOnly = host.querySelector<HTMLButtonElement>('button[aria-label="Memo only"]')
      const model = host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')
      const newChat = host.querySelector<HTMLButtonElement>('button[aria-label="New chat"]')
      expect(composer).not.toBeNull()
      expect(attachmentPicker).not.toBeNull()
      expect(attachmentButton).not.toBeNull()
      expect(memoOnly).not.toBeNull()
      expect(model).not.toBeNull()
      expect(newChat).not.toBeNull()
      attachmentButton!.focus()
      expect(document.activeElement).toBe(attachmentButton)
      let attachmentPickerClicks = 0
      attachmentPicker!.addEventListener('click', () => { attachmentPickerClicks += 1 })
      attachmentButton!.click()
      expect(attachmentPickerClicks).toBe(1)

      model!.value = 'compact'
      model!.dispatchEvent(new Event('input', { bubbles: true }))
      const attachment = new File(['reference'], 'reference.txt', { type: 'text/plain' })
      Object.defineProperty(attachmentPicker!, 'files', { configurable: true, value: [attachment] })
      attachmentPicker!.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('reference.txt'))
      memoOnly!.click()
      await waitFor(() => expect(host.textContent).toContain('Remove attached files before enabling memo-only mode.'))
      expect(memoOnly!.getAttribute('aria-pressed')).toBe('false')
      host.querySelector<HTMLButtonElement>('button[title="Remove reference.txt"]')!.click()
      await waitFor(() => expect(host.textContent).not.toContain('reference.txt'))
      memoOnly!.click()
      expect(memoOnly!.getAttribute('aria-pressed')).toBe('true')

      composer!.value = 'Saved memo'
      composer!.dispatchEvent(new Event('input', { bubbles: true }))
      composer!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await waitFor(() => expect(memoWrites).toEqual(['Saved memo']))
      await waitFor(() => expect(memoOnly!.disabled).toBe(false))

      memoOnly!.click()
      newChat!.click()
      await waitFor(() => expect(host.textContent).toContain('New conversation'))
      expect(host.textContent).toContain('Earlier question')
      const requestAttachment = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(attachmentPicker!, 'files', { configurable: true, value: [requestAttachment] })
      attachmentPicker!.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))
      composer!.value = 'Ask in a new chat'
      composer!.dispatchEvent(new Event('input', { bubbles: true }))
      const enter = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
      composer!.dispatchEvent(enter)
      expect(enter.defaultPrevented).toBe(true)
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).toMatchObject({ subjectNoteId: subject.noteId, userMarkdown: 'Ask in a new chat', model: 'compact' })
      expect(requests[0]?.conversationNotebookId).toBeUndefined()
      expect(requests[0]?.attachments).toEqual([{
        contentBase64: 'Y29udGV4dA==', mediaType: 'text/plain', originalFilename: 'context.txt',
      }] as AgentChatAttachmentInput[])
      await waitFor(() => expect(host.textContent).toContain('New conversation'))
      expect(host.textContent).toContain('Earlier question')
      await waitFor(() => expect(host.textContent).toContain('Ask in a new chat'))
      const transcriptChildren = Array.from(host.querySelector('.chat-transcript')!.children)
      const earlierIndex = transcriptChildren.findIndex((element) => element.textContent?.includes('Earlier question'))
      const boundaryIndex = transcriptChildren.findIndex((element) => element.classList.contains('new-conversation-boundary'))
      const newTurnIndex = transcriptChildren.findIndex((element) => element.textContent?.includes('Ask in a new chat'))
      expect(earlierIndex).toBeLessThan(boundaryIndex)
      expect(boundaryIndex).toBeLessThan(newTurnIndex)

      composer!.value = 'Continue the new chat'
      composer!.dispatchEvent(new Event('input', { bubbles: true }))
      composer!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await waitFor(() => expect(requests).toHaveLength(2))
      expect(requests[1]?.conversationNotebookId).toBe('conversation-new')
      expect(requests[1]?.mode).toBeUndefined()

      // Switching to note edit mode mid-conversation keeps the thread and
      // marks the next turn as an edit request.
      const noteEdit = host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')
      expect(noteEdit).not.toBeNull()
      expect(noteEdit!.disabled).toBe(false)
      noteEdit!.click()
      expect(noteEdit!.getAttribute('aria-pressed')).toBe('true')
      composer!.value = 'Apply what we discussed to the note'
      composer!.dispatchEvent(new Event('input', { bubbles: true }))
      composer!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await waitFor(() => expect(requests).toHaveLength(3))
      expect(requests[2]).toMatchObject({ conversationNotebookId: asNotebookId('conversation-new'), mode: 'edit' })
    } finally {
      dispose()
      host.remove()
    }
  })
})
