import { noteId as asNoteId, notebookId as asNotebookId } from '../notes/ids'
import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { describe, expect, test } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import type { WebAppSettings } from '../notes/settings'
import type { AgentChatAttachmentInput, AgentChatMessageResult, AgentReplyStreamPoll, Note } from '../notes/types'
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

const pendingStreamTurn: Note = {
  noteId: asNoteId('turn-streaming'), notebookId: asNotebookId('conversation-new'), noteNumber: 1,
  title: 'Streaming question', bodyMarkdown: '## User\nStreaming question', readOnly: false,
  createdAt: '2026-08-13T00:02:00Z', updatedAt: '2026-08-13T00:02:00Z',
  metaJSON: JSON.stringify({ kaibaChat: { status: 'pending', userMarkdown: 'Streaming question' } }),
}

// A persisted turn that failed while in note-edit mode. Retrying it must
// resend mode: "edit"; silently downgrading it to a memo would let a plain
// answer masquerade as an applied edit.
const failedMemoTurn: Note = {
  noteId: asNoteId('turn-failed-memo'), notebookId: asNotebookId('conversation-old'), noteNumber: 1,
  title: 'Summarize the note', bodyMarkdown: '## User\nSummarize the note', readOnly: false,
  createdAt: '2026-08-13T00:01:00Z', updatedAt: '2026-08-13T00:01:00Z',
  metaJSON: JSON.stringify({ kaibaChat: { status: 'failed', userMarkdown: 'Summarize the note' } }),
}

const failedEditTurn: Note = {
  noteId: asNoteId('turn-failed-edit'), notebookId: asNotebookId('conversation-old'), noteNumber: 1,
  title: 'Rewrite the note', bodyMarkdown: '## User\nRewrite the note', readOnly: false,
  createdAt: '2026-08-13T00:01:00Z', updatedAt: '2026-08-13T00:01:00Z',
  metaJSON: JSON.stringify({ kaibaChat: { status: 'failed', mode: 'edit', userMarkdown: 'Rewrite the note' } }),
}

function catalogPayload() {
  return {
    models: [
      { modelId: 'configured', displayName: 'Configured model' },
      { modelId: 'compact', displayName: 'Compact model' },
    ],
    configuredModel: 'configured',
    discoveryAvailable: true,
  }
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

function testStore(
  requests: Array<Record<string, unknown>>,
  memoWrites: string[],
  options: {
    /** Per-call outcome, in order: 'ok' resolves, 'network' throws a transport
     * error. Calls past the end of the script resolve. */
    agentModelsScript?: Array<'ok' | 'network'>
    /** Per-call gates, in order. Each call parks on its gate before settling,
     * so a test can make an EARLIER call settle AFTER a later one. */
    agentModelsGates?: Array<{ wait: Promise<void>; outcome: 'ok' | 'network' }>
    failedEditTurn?: boolean
    failedMemoTurn?: boolean
    /** Hands the caller a way to bump `catalogRevision`, the signal the app
     * increments only after a catalog reload SUCCEEDS — i.e. the server is
     * reachable again. */
    bindBumpCatalog?: (bump: () => void) => void
    /** Hands the caller a way to lock the notebook mid-test. `notebook()` reads
     * a signal so `noteEditAvailable` recomputes and the read-only effect fires,
     * which is the only reachable way to clear `noteEdit()` during a send. */
    bindLockNotebook?: (lock: () => void) => void
    /** Drives a pending turn through the reply-stream route. */
    streamPoll?: (call: number) => Promise<AgentReplyStreamPoll>
  } = {},
): AppStore {
  let agentModelsCalls = 0
  const [catalogRevision, setCatalogRevision] = createSignal(0)
  const [notebookReadOnly, setNotebookReadOnly] = createSignal(false)
  options.bindLockNotebook?.(() => setNotebookReadOnly(true))
  options.bindBumpCatalog?.(() => setCatalogRevision((revision) => revision + 1))
  let newConversationCreated = false
  let streamPollCalls = 0
  const state = {
    noteId: subject.noteId,
    notebookId: subject.notebookId,
    note: subject,
    settings: { agentModel: 'configured', fontScale: 1 },
    notebookRevisions: {},
    // A getter so reads inside an effect track the signal, matching the real
    // store where catalogRevision lives in createStore.
    get catalogRevision() { return catalogRevision() },
  }
  const client = {
    agentModels: async () => {
      agentModelsCalls += 1
      const gate = options.agentModelsGates?.[agentModelsCalls - 1]
      if (gate) {
        await gate.wait
        if (gate.outcome === 'network') throw new NoteTransportError('Failed to fetch', 'network')
        return catalogPayload()
      }
      if (options.agentModelsScript?.[agentModelsCalls - 1] === 'network') {
        throw new NoteTransportError('Failed to fetch', 'network')
      }
      return catalogPayload()
    },
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
    notes: async (notebookId: NotebookId) => {
      if (notebookId === 'conversation-new') return options.streamPoll ? [pendingStreamTurn] : [newTurn]
      if (options.failedMemoTurn) return [failedMemoTurn]
      return options.failedEditTurn ? [failedEditTurn] : [earlierTurn]
    },
    sendAgentChatMessage: async (request: Record<string, unknown>): Promise<AgentChatMessageResult> => {
      requests.push(request)
      newConversationCreated = true
      return options.streamPoll
        ? { conversationNotebookId: asNotebookId('conversation-new'), turnNoteId: pendingStreamTurn.noteId, agentStatus: 'pending' }
        : { conversationNotebookId: asNotebookId('conversation-new'), turnNoteId: null, agentStatus: 'answered' }
    },
    pollAgentReplyStream: async () => {
      if (!options.streamPoll) throw new Error('agent reply stream was not configured')
      streamPollCalls += 1
      return options.streamPoll(streamPollCalls)
    },
    addNoteComment: async (_noteId: string, body: string) => { memoWrites.push(body) },
  } as unknown as NoteGraphQLClient
  return {
    state,
    client,
    notes: () => [subject],
    notebook: () => ({ notebookId: subject.notebookId, title: 'Notebook', readOnly: notebookReadOnly() }),
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

  test('the extension controls are enabled, and memo-only never disables the note-edit toggle', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={testStore([], [])} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const model = host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      const attach = host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!
      const noteEdit = host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!
      const memoOnly = host.querySelector<HTMLButtonElement>('button[aria-label="Memo only"]')!
      await waitFor(() => {
        expect(model.disabled).toBe(false)
        expect(attach.disabled).toBe(false)
        expect(noteEdit.disabled).toBe(false)
      })

      // Memo-only rests the model and attachment controls, but the note-edit
      // toggle must stay reachable so its "Disable memo-only mode before
      // enabling note edit mode." explanation can still fire.
      memoOnly.click()
      await waitFor(() => expect(memoOnly.getAttribute('aria-pressed')).toBe('true'))
      await waitFor(() => expect(model.disabled).toBe(true))
      expect(attach.disabled).toBe(true)
      expect(noteEdit.disabled).toBe(false)
      expect(noteEdit.getAttribute('aria-disabled')).toBe('false')
      noteEdit.click()
      await waitFor(() => expect(host.textContent)
        .toContain('Disable memo-only mode before enabling note edit mode.'))
      expect(noteEdit.getAttribute('aria-pressed')).toBe('false')
    } finally {
      dispose()
      host.remove()
    }
  })

  // A discovery failure is a transport error, not a capability signal. Nothing
  // the user staged may vanish because of it, and the failure is announced.
  test('a file staged before discovery fails keeps its chip and the failure is reported', async () => {
    let releaseDiscovery!: () => void
    const gate = new Promise<void>((resolve) => { releaseDiscovery = resolve })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        agentModelsGates: [{ wait: gate, outcome: 'network' }],
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['context'], 'staged.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('staged.txt'))

      releaseDiscovery()
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      expect(host.textContent).toContain('staged.txt')
      expect(host.querySelector<HTMLInputElement>('input[type="file"]')!.disabled).toBe(false)
    } finally {
      dispose()
      host.remove()
    }
  })

  // The Retry button feeds noteEdit from the PERSISTED turn, not from the
  // note-edit toggle. Retrying a failed edit turn must resend mode: "edit";
  // downgrading it to a memo would let a plain answer masquerade as an applied
  // edit.
  test('retrying a failed note-edit turn resends mode "edit"', async () => {
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], { failedEditTurn: true })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Rewrite the note'))
      const retry = Array.from(host.querySelectorAll('button'))
        .find((button) => button.textContent === 'Retry') as HTMLButtonElement
      expect(retry).not.toBeUndefined()
      expect(retry.disabled).toBe(false)
      retry.click()
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).toMatchObject({ conversationNotebookId: 'conversation-old', mode: 'edit' })
    } finally {
      dispose()
      host.remove()
    }
  })

  // Discovery only populates the model picker. Its failure is reported once,
  // leaves every control usable, and is retried when the app's own catalog
  // reload succeeds and bumps `catalogRevision`.
  test('a failed discovery is reported, leaves the controls usable, and is retried on the next catalog revision', async () => {
    let bumpCatalog!: () => void
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        agentModelsScript: ['network', 'ok'],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      expect(model().disabled).toBe(false)
      expect(model().options).toHaveLength(0)
      expect(host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!.disabled).toBe(false)
      expect(host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!.disabled).toBe(false)

      // The server comes back; the app's own catalog reload succeeds and bumps
      // catalogRevision. Discovery re-runs on that and the banner retires.
      bumpCatalog()
      await waitFor(() => expect(model().options).toHaveLength(2))
      expect(host.querySelector('.note-inline-error')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  // The `.catch` can fire AFTER a success. If it cleared the model list, the
  // normalization effect would re-derive the selection from an empty catalog
  // and silently overwrite — and debounce-persist — the user's chosen model.
  test('a transient discovery failure after a success does not rewrite the persisted model', async () => {
    let bumpCatalog!: () => void
    const store = testStore([], [], {
      agentModelsScript: ['ok', 'network'],
      bindBumpCatalog: (bump) => { bumpCatalog = bump },
    })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={store} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const model = host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model.disabled).toBe(false))

      // The user picks a non-default model through the real control.
      model.value = 'compact'
      model.dispatchEvent(new Event('input', { bubbles: true }))
      await waitFor(() => expect(store.state.settings.agentModel).toBe('compact'))

      // The server blips on the next catalog refresh.
      bumpCatalog()
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      expect(store.state.settings.agentModel).toBe('compact')
      expect(model.options).toHaveLength(2)
    } finally {
      dispose()
      host.remove()
    }
  })

  // Discovery is re-runnable and `catalogRevision` is bumped by a debounced
  // refresh, so a slow request can settle AFTER a newer one. A stale rejection
  // must not overwrite a known-good catalog.
  test('a stale discovery rejection cannot overwrite a newer successful one', async () => {
    let releaseFirst!: () => void
    let releaseSecond!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const second = new Promise<void>((resolve) => { releaseSecond = resolve })
    let bumpCatalog!: () => void
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        agentModelsGates: [{ wait: first, outcome: 'network' }, { wait: second, outcome: 'ok' }],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      // Second run starts while the first is still in flight.
      bumpCatalog()
      await settle()

      // Newer run wins first.
      releaseSecond()
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model().options).toHaveLength(2))

      // The stale first run now rejects; it must be ignored, banner included.
      releaseFirst()
      await settle(); await settle(); await settle()
      expect(model().options).toHaveLength(2)
      expect(host.querySelector('.note-inline-error')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  // `send()` captures `noteEdit()` before its awaits. The read-only effect
  // clears the toggle when the note stops being editable, and it is not gated
  // on `busy()`, so it can fire INSIDE the send's await window; re-reading the
  // toggle at the builder would strip `mode` from a request the user submitted
  // as an edit.
  test('a mid-send read-only lock cannot downgrade an already-admitted note edit', async () => {
    let releaseFirst!: () => void
    let releaseAttachmentRead!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const attachmentRead = new Promise<void>((resolve) => { releaseAttachmentRead = resolve })
    let lockNotebook!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsGates: [{ wait: first, outcome: 'ok' }],
        bindLockNotebook: (lock) => { lockNotebook = lock },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      releaseFirst()
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model().disabled).toBe(false))

      const noteEdit = host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!
      noteEdit.click()
      await waitFor(() => expect(noteEdit.getAttribute('aria-pressed')).toBe('true'))

      // The staged file is only a way to park the send inside its await
      // window; the assertion is about `mode`, not about attachments.
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))
      Object.defineProperty(staged, 'arrayBuffer', {
        configurable: true,
        value: async () => {
          await attachmentRead
          return new TextEncoder().encode('context').buffer
        },
      })

      const composer = host.querySelector('textarea')!
      composer.value = 'Apply what we discussed to the note'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle()
      expect(requests).toHaveLength(0)

      // The note stops being editable WHILE the send is parked. The effect
      // clears the toggle — visible in `aria-pressed` — but the request was
      // already admitted as an edit.
      lockNotebook()
      await waitFor(() => expect(noteEdit.getAttribute('aria-pressed')).toBe('false'))
      expect(requests).toHaveLength(0)

      releaseAttachmentRead()
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).toMatchObject({ mode: 'edit' })
    } finally {
      dispose()
      host.remove()
    }
  })

  // A discovery failure after a success changes nothing about what a send
  // carries: the chip stays, and the next message uploads it.
  test('a send after a failed discovery still carries the staged attachment', async () => {
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsScript: ['ok', 'network'],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const model = host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model.options).toHaveLength(2))

      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))

      bumpCatalog()
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      expect(host.textContent).toContain('context.txt')
      expect(picker.disabled).toBe(false)

      const composer = host.querySelector('textarea')!
      composer.value = 'Use the attached file'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).toMatchObject({ model: 'configured' })
      expect(requests[0]?.attachments).toEqual([{
        contentBase64: 'Y29udGV4dA==', mediaType: 'text/plain', originalFilename: 'context.txt',
      }] as AgentChatAttachmentInput[])
      await waitFor(() => expect(host.textContent).not.toContain('context.txt'))
    } finally {
      dispose()
      host.remove()
    }
  })

  // The builder takes four `retry ? … : …` arms. A retry issued with chips
  // staged and New chat pending must still be a retry: it carries no
  // attachments and posts back into the FAILED TURN's conversation, not into a
  // new one.
  test('a retry ignores staged chips and a pending New chat', async () => {
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], { failedMemoTurn: true })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Summarize the note'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      await waitFor(() => expect(picker.disabled).toBe(false))

      // New chat FIRST, then stage — `startNewChat` resets the composer, so
      // staging before it would clear the chips and make the attachments
      // assertion below vacuous. Measured: with the other order, mutation 16
      // survived this very test.
      host.querySelector<HTMLButtonElement>('button[aria-label="New chat"]')!.click()
      await settle()

      // The builder would happily put staged chips on the wire if the retry
      // arm stopped withholding them.
      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))

      const retry = [...host.querySelectorAll('button')].find((b) => b.textContent === 'Retry')!
      retry.click()
      await settle(); await settle(); await settle()
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).not.toHaveProperty('attachments')
      // A retry re-sends INTO the failed turn's conversation. A pending New chat
      // must not turn it into the first message of a different one.
      expect(requests[0]).toMatchObject({ conversationNotebookId: 'conversation-old' })
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 7 MID. `startNewChat` is not gated on `busy()` and the New chat button
  // carries no `disabled` binding, so a click during the await window reached the
  // builder's conversation reads. The submitted message silently started a NEW
  // conversation, and the reset half-applied to it: `setAttachments([])` cleared
  // the composer while the same file still rode out on the wire. Capturing both
  // reads settles it in one direction — the admitted request keeps its
  // conversation AND its chips.
  test('a mid-send New chat cannot reroute an already-admitted message or half-apply its reset', async () => {
    let releaseAttachmentRead!: () => void
    const attachmentRead = new Promise<void>((resolve) => { releaseAttachmentRead = resolve })
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={testStore(requests, [])} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))

      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))
      Object.defineProperty(staged, 'arrayBuffer', {
        configurable: true,
        value: async () => {
          await attachmentRead
          return new TextEncoder().encode('context').buffer
        },
      })

      const composer = host.querySelector('textarea')!
      composer.value = 'Add this to the earlier conversation'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle()
      expect(requests).toHaveLength(0)

      // New chat is busy-gated, so the click cannot land inside the await window
      // at all. Asserted, not assumed: this is the binding whose absence let an
      // accepted click be discarded.
      const newChat = () => host.querySelector<HTMLButtonElement>('button[aria-label="New chat"]')!
      expect(newChat().disabled).toBe(true)
      newChat().click()
      await settle()
      expect(requests).toHaveLength(0)

      releaseAttachmentRead()
      await waitFor(() => expect(requests).toHaveLength(1))
      // The message the user submitted into the existing conversation stays in it.
      expect(requests[0]).toMatchObject({ conversationNotebookId: 'conversation-old' })
      // And the reset does not half-apply: the chip the guard admitted is still
      // the chip on the wire, rather than cleared in the composer only.
      expect(requests[0]?.attachments).toHaveLength(1)

      // The other half of the same defect: capturing the conversation values
      // stopped the reroute, but the post-send reset still ran
      // `setNewConversation(false)`, so a click the live button ACCEPTED was
      // then silently discarded — the user's next message went back into the
      // old conversation. Gating the button closes that by making the control
      // unavailable mid-send, so nothing is accepted and nothing is discarded.
      // Proven here rather than asserted: the button re-enables on completion
      // and the click then does take effect on the next message.
      expect(newChat().disabled).toBe(false)
      newChat().click()
      const composer2 = host.querySelector('textarea')!
      composer2.value = 'and now a fresh conversation'
      composer2.dispatchEvent(new Event('input', { bubbles: true }))
      composer2.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await waitFor(() => expect(requests).toHaveLength(2))
      expect(requests[1]).not.toHaveProperty('conversationNotebookId')
    } finally {
      dispose()
      host.remove()
    }
  })
  // Step 7 adversarial MID. The chip-remove button was the one composer control
  // with no `disabled` binding of any kind: every other extension control routes
  // through `agentComposerExtensionsEnabled`, which already rests on `busy`.
  // `send()` captures `stagedAttachments` before the guard, so a mid-send click
  // removed the chip from the composer while the captured file was still
  // base64'd and uploaded — the UI confirmed a withdrawal the wire ignored, and
  // the half that escaped is the irreversible one. Same settlement as New chat:
  // make the control unavailable while a send is in flight, so no withdrawal is
  // accepted that the request cannot honour.
  test('a mid-send chip removal is refused rather than accepted and inverted', async () => {
    let releaseAttachmentRead!: () => void
    const attachmentRead = new Promise<void>((resolve) => { releaseAttachmentRead = resolve })
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={testStore(requests, [])} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))

      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['secret'], 'secret.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('secret.txt'))
      // The attachment read is the hold: it parks the send between the guard and
      // the builder, which is the only window in which the chip is reachable.
      Object.defineProperty(staged, 'arrayBuffer', {
        configurable: true,
        value: async () => {
          await attachmentRead
          return new TextEncoder().encode('secret').buffer
        },
      })

      const composer = host.querySelector('textarea')!
      composer.value = 'Send with the file attached'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle()
      expect(requests).toHaveLength(0)

      const chip = () => host.querySelector<HTMLButtonElement>('button[title="Remove secret.txt"]')
      expect(chip()!.disabled).toBe(true)
      chip()!.click()
      await settle()
      // Refused, not accepted: the chip stays, so the composer never claims a
      // withdrawal the in-flight request is going to contradict.
      expect(chip()).not.toBeNull()

      releaseAttachmentRead()
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]?.attachments).toHaveLength(1)

      // And the control is only rested, not dead: once the send completes the
      // button takes a removal again. Proven rather than asserted, the same way
      // the New chat gate is.
      const second = new File(['later'], 'later.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [second] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('later.txt'))
      const laterChip = () => host.querySelector<HTMLButtonElement>('button[title="Remove later.txt"]')
      expect(laterChip()!.disabled).toBe(false)
      laterChip()!.click()
      await waitFor(() => expect(laterChip()).toBeNull())
    } finally {
      dispose()
      host.remove()
    }
  })

  test('stream payload resync clears an incomplete partial reply until durable completion', async () => {
    let releaseSecondPoll!: () => void
    const secondPoll = new Promise<void>((resolve) => { releaseSecondPoll = resolve })
    let markSecondPollStarted!: () => void
    const secondPollStarted = new Promise<void>((resolve) => { markSecondPollStarted = resolve })
    let markThirdPollStarted!: () => void
    const thirdPollStarted = new Promise<void>((resolve) => { markThirdPollStarted = resolve })
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <MemoTab app={testStore(requests, [], {
      streamPoll: async (call) => {
        if (call === 1) {
          return {
            cursor: 1, chunks: ['prefix-fragment'], done: false,
            status: null, message: null, resync: false,
          }
        }
        if (call === 2) {
          markSecondPollStarted()
          await secondPoll
          return {
            cursor: 2, chunks: ['suffix-fragment'], done: false,
            status: null, message: null, resync: true,
          }
        }
        markThirdPollStarted()
        return await new Promise<AgentReplyStreamPoll>(() => {})
      },
    })} />, host)
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const composer = host.querySelector('textarea')!
      composer.value = 'Streaming question'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))

      await waitFor(() => expect(host.textContent).toContain('prefix-fragment'))
      await secondPollStarted
      releaseSecondPoll()
      await thirdPollStarted
      expect(host.textContent).not.toContain('prefix-fragment')
      expect(host.textContent).not.toContain('suffix-fragment')
      expect(host.textContent).toContain('Waiting for the agent')
    } finally {
      dispose()
      host.remove()
    }
  })
})
