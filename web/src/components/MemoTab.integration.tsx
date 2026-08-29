import { noteId as asNoteId, notebookId as asNotebookId } from '../notes/ids'
import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { describe, expect, test } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
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

// A persisted turn that failed while in note-edit mode. Retrying it must
// resend mode: "edit"; silently downgrading it to a memo is the masquerade
// web-chatbook-ui.md:254-257 forbids.
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
    rejectAgentModels?: boolean
    rejectAgentModelsAfter?: Promise<void>
    resolveAgentModelsAfter?: Promise<void>
    transportFailuresBeforeSuccess?: number
    /** Resolve this many calls, then fail every later one — the shape of a
     * server that answered once and then hit a blip. */
    failAfterSuccessfulCalls?: number
    /** Per-call outcome, in order: 'ok' resolves, 'network' throws a retryable
     * transport error. Lets a test script an outage/recovery/outage sequence. */
    agentModelsScript?: Array<'ok' | 'network'>
    /** Per-call gates, in order. Each call parks on its gate before settling,
     * so a test can make an EARLIER call settle AFTER a later one. */
    agentModelsGates?: Array<{ wait: Promise<void>; outcome: 'ok' | 'network' | 'graphql' }>
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
  } = {},
): AppStore {
  let transportFailures = 0
  let agentModelsCalls = 0
  const [catalogRevision, setCatalogRevision] = createSignal(0)
  const [notebookReadOnly, setNotebookReadOnly] = createSignal(false)
  options.bindLockNotebook?.(() => setNotebookReadOnly(true))
  options.bindBumpCatalog?.(() => setCatalogRevision((revision) => revision + 1))
  let newConversationCreated = false
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
      // An older server has no `agentModels` field at all, so the query itself
      // rejects. That is the composer-extension availability signal.
      agentModelsCalls += 1
      const gate = options.agentModelsGates?.[agentModelsCalls - 1]
      if (gate) {
        await gate.wait
        if (gate.outcome === 'network') throw new NoteTransportError('Failed to fetch', 'network')
        if (gate.outcome === 'graphql') {
          throw new NoteTransportError('Cannot query field "agentModels".', 'graphql')
        }
        return catalogPayload()
      }
      const scripted = options.agentModelsScript?.[agentModelsCalls - 1]
      if (scripted === 'network') throw new NoteTransportError('Failed to fetch', 'network')
      if (scripted === 'ok') return catalogPayload()
      if (options.failAfterSuccessfulCalls !== undefined
        && agentModelsCalls > options.failAfterSuccessfulCalls) {
        throw new NoteTransportError('Failed to fetch', 'network')
      }
      // An older server rejects the QUERY, which the client surfaces as a
      // 'graphql' NoteTransportError. Transport failures are a different kind
      // and must not be read as a capability verdict.
      if (options.transportFailuresBeforeSuccess !== undefined
        && transportFailures < options.transportFailuresBeforeSuccess) {
        transportFailures += 1
        throw new NoteTransportError('Failed to fetch', 'network')
      }
      if (options.resolveAgentModelsAfter) await options.resolveAgentModelsAfter
      if (options.rejectAgentModelsAfter) {
        await options.rejectAgentModelsAfter
        throw new NoteTransportError('Cannot query field "agentModels".', 'graphql')
      }
      if (options.rejectAgentModels) {
        throw new NoteTransportError('Cannot query field "agentModels".', 'graphql')
      }
      return {
        models: [
          { modelId: 'configured', displayName: 'Configured model' },
          { modelId: 'compact', displayName: 'Compact model' },
        ],
        configuredModel: 'configured',
        discoveryAvailable: true,
      }
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
      if (notebookId === 'conversation-new') return [newTurn]
      if (options.failedMemoTurn) return [failedMemoTurn]
      return options.failedEditTurn ? [failedEditTurn] : [earlierTurn]
    },
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

  // web-chatbook-ui.md:245 and :254-257. The catalog-availability signal is
  // whether the `agentModels` query RESOLVED, so these two tests drive the real
  // discovery effect through MemoTab rather than passing a literal prop.
  test('an older server whose agentModels query rejects rests every composer extension control', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], { rejectAgentModels: true })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      await waitFor(() => {
        expect(host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!.disabled).toBe(true)
        expect(host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!.disabled).toBe(true)
        expect(host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!.disabled).toBe(true)
      })
    } finally {
      dispose()
      host.remove()
    }
  })

  test('an available catalog leaves the extension controls enabled, and memo-only never disables the note-edit toggle', async () => {
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

  // Pins the discovery `.catch`'s setAttachments([]) (MemoTab.tsx:147). Without
  // that line a file staged before discovery settles UNAVAILABLE keeps its chip
  // rendered while buildAgentChatComposerRequest silently withholds
  // `attachments` — the silent drop web-chatbook-ui.md:245 forbids.
  //
  // Reachability, established by probe rather than assumed: because
  // catalogAvailable initializes false, the picker renders DISABLED from first
  // paint, so a real user cannot reach this ordering through the control today.
  // The change handler is nonetheless live (`change` is not a Solid-delegated
  // event, so it is a direct addEventListener that fires on a disabled input),
  // which is exactly why the defensive clear is worth pinning: any path that
  // stages while discovery is still pending must not survive a failed catalog.
  test('a file staged before discovery settles unavailable does not keep its chip', async () => {
    let releaseDiscovery!: () => void
    const gate = new Promise<void>((resolve) => { releaseDiscovery = resolve })
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], { rejectAgentModelsAfter: gate })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['context'], 'staged.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      // The chip is really there while discovery is still pending, so the
      // post-rejection assertion below cannot pass vacuously.
      await waitFor(() => expect(host.textContent).toContain('staged.txt'))

      releaseDiscovery()
      await waitFor(() => expect(host.textContent).not.toContain('staged.txt'))
      expect(host.querySelector('.attachment-chips')).toBeNull()
      // The drop is announced, not silent. Without this the chip could vanish
      // with no explanation and the suite would not notice.
      expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('staged files were removed')
    } finally {
      dispose()
      host.remove()
    }
  })

  // Adversarial-review finding 1 (HIGH). The Retry button feeds noteEdit from
  // the PERSISTED turn, not from the note-edit toggle, so it bypasses every
  // control the capability gate disables. Retrying a failed edit turn before
  // discovery settles must not silently downgrade it to a memo against a
  // capable server: the note would never be edited while the turn reports
  // answered — exactly the masquerade web-chatbook-ui.md:254-257 forbids.
  test('retrying a failed note-edit turn never silently downgrades it to a memo', async () => {
    let releaseDiscovery!: () => void
    const gate = new Promise<void>((resolve) => { releaseDiscovery = resolve })
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        resolveAgentModelsAfter: gate, failedEditTurn: true,
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Rewrite the note'))
      const retry = () => Array.from(host.querySelectorAll('button'))
        .find((button) => button.textContent === 'Retry') as HTMLButtonElement
      expect(retry()).not.toBeUndefined()

      // Capable server, catalog not yet known: the edit retry must not be
      // offered, because sending it now would withhold mode: "edit".
      expect(retry().disabled).toBe(true)
      retry().click()
      await settle()
      expect(requests).toHaveLength(0)

      // Once the catalog answers, the same retry is offered and keeps its mode.
      releaseDiscovery()
      await waitFor(() => expect(retry().disabled).toBe(false))
      retry().click()
      await waitFor(() => expect(requests).toHaveLength(1))
      expect(requests[0]).toMatchObject({ mode: 'edit' })
    } finally {
      dispose()
      host.remove()
    }
  })

  // Adversarial-review finding 2 (MID). A transient network or HTTP failure is
  // not evidence that the server is old. Collapsing every rejection kind into
  // "older server" permanently rested every extension control for the whole
  // session against a capable server, with no message and no recovery.
  test('a transient transport failure is reported and retried, not read as an older server', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], { transportFailuresBeforeSuccess: 1 })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      // Discovery recovers, so a capable server is not degraded for the session.
      await waitFor(() => {
        expect(host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!.disabled).toBe(false)
        expect(host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!.disabled).toBe(false)
      })
    } finally {
      dispose()
      host.remove()
    }
  })

  test('a transport failure that never clears surfaces an explanation instead of failing silently', async () => {
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], { transportFailuresBeforeSuccess: 99 })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      // Still fail-closed: the controls rest rather than sending fields the
      // server may not understand.
      expect(host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!.disabled).toBe(true)
    } finally {
      dispose()
      host.remove()
    }
  })

  // Adversarial-review escalation. Three immediate attempts are consumed in
  // milliseconds, so any real outage — server restart, wifi handoff, sleep/wake
  // — outlives the budget. Without a reconnect trigger the controls stay dead
  // for the whole session against a server that recovered seconds later, while
  // the banner promises a recovery nothing can produce.
  test('discovery recovers when the server becomes reachable again after the retry budget is spent', async () => {
    let bumpCatalog!: () => void
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        transportFailuresBeforeSuccess: 3,
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      // Budget exhausted: controls rest and the failure is reported.
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      expect(host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!.disabled).toBe(true)

      // The server comes back; the app's own catalog reload succeeds and bumps
      // catalogRevision. Discovery must re-run on that.
      bumpCatalog()
      await waitFor(() => {
        expect(host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!.disabled).toBe(false)
        expect(host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!.disabled).toBe(false)
      })
      // The banner that promised recovery is retired once recovery happens.
      expect(host.querySelector('.note-inline-error')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 7 regression. Making discovery re-runnable means the `.catch` can now
  // fire AFTER a success. If it clears the model list on a merely transient
  // failure, the normalization effect re-derives the selection from an empty
  // catalog and silently overwrites — and debounce-persists — the user's
  // chosen model. A transport blip must never rewrite persisted settings.
  test('a transient discovery failure after a success does not rewrite the persisted model', async () => {
    let bumpCatalog!: () => void
    const store = testStore([], [], {
      failAfterSuccessfulCalls: 1,
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
      await settle(); await settle(); await settle()
      expect(store.state.settings.agentModel).toBe('compact')
    } finally {
      dispose()
      host.remove()
    }
  })

  // The retry budget must be per outage, not per session: a success has to earn
  // the next outage a fresh set of immediate attempts, or the second blip of a
  // session is condemned on its first try — the very thing this task removed.
  test('a success refreshes the retry budget so a later blip is retried, not condemned', async () => {
    let bumpCatalog!: () => void
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        // exhaust, recover, blip again, recover again
        agentModelsScript: ['network', 'network', 'network', 'ok', 'network', 'ok'],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      // Budget spent on the first outage.
      await waitFor(() => expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('agent model catalog'))
      bumpCatalog()
      await waitFor(() => expect(model().disabled).toBe(false))
      expect(host.querySelector('.note-inline-error')).toBeNull()

      // Second outage. With a refreshed budget this retries and recovers, so no
      // banner ever appears. Without the reset the budget is already spent and
      // the very first failure reports instead of retrying.
      bumpCatalog()
      await settle(); await settle(); await settle(); await settle()
      expect(host.querySelector('.note-inline-error')).toBeNull()
      expect(model().disabled).toBe(false)
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
        // A stale GRAPHQL rejection is a permanent older-server verdict; a stale
        // network one would self-heal via the retry and prove nothing.
        agentModelsGates: [{ wait: first, outcome: 'graphql' }, { wait: second, outcome: 'ok' }],
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
      await waitFor(() => expect(model().disabled).toBe(false))

      // The stale first run now rejects; it must be ignored.
      releaseFirst()
      await settle(); await settle(); await settle()
      expect(model().disabled).toBe(false)
      expect(host.querySelector('.note-inline-error')).toBeNull()
    } finally {
      dispose()
      host.remove()
    }
  })

  // The catch's setCatalogAvailable(false) stopped being a no-op the moment
  // discovery became re-runnable: a mid-session server rollback (a proxy or
  // deploy that starts answering the older-server way) makes the .catch fire
  // AFTER a success, and this is the line that rests the controls again. It
  // enforces the headline invariant — an older server leaves the extension
  // controls disabled — on the one path where availability goes true -> false.
  test('a server that stops understanding agentModels mid-session rests the controls again', async () => {
    let releaseFirst!: () => void
    let releaseSecond!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const second = new Promise<void>((resolve) => { releaseSecond = resolve })
    let bumpCatalog!: () => void
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore([], [], {
        agentModelsGates: [{ wait: first, outcome: 'ok' }, { wait: second, outcome: 'graphql' }],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      releaseFirst()
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model().disabled).toBe(false))

      // The server is rolled back; the next discovery rejects at the schema.
      bumpCatalog()
      await settle()
      releaseSecond()
      await waitFor(() => expect(model().disabled).toBe(true))
      expect(host.querySelector<HTMLButtonElement>('button[aria-label="Attach text files"]')!.disabled).toBe(true)
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 7 HIGH. The masquerade guard covered only the retry path, but the
  // DIRECT composer send is strictly more reachable: the Retry button is
  // disabled while the catalog is unknown, the textarea and submit are not.
  // Nothing resets noteEdit() when availability flips true -> false, so a
  // latched toggle plus a mid-session rollback sent `mode` withheld with no
  // refusal and no error — the masquerade web-chatbook-ui.md:254-257 forbids.
  test('a direct send never downgrades a latched note-edit to a plain memo', async () => {
    let releaseFirst!: () => void
    let releaseSecond!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const second = new Promise<void>((resolve) => { releaseSecond = resolve })
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsGates: [{ wait: first, outcome: 'ok' }, { wait: second, outcome: 'graphql' }],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      releaseFirst()
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model().disabled).toBe(false))

      // User engages note edit against a healthy catalog.
      const noteEdit = host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!
      noteEdit.click()
      await waitFor(() => expect(noteEdit.getAttribute('aria-pressed')).toBe('true'))

      // Server is rolled back mid-session.
      bumpCatalog()
      await settle()
      releaseSecond()
      await waitFor(() => expect(model().disabled).toBe(true))

      // The composer is still enabled, so the user can submit. It must refuse.
      const composer = host.querySelector('textarea')!
      composer.value = 'Apply what we discussed to the note'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle(); await settle(); await settle()
      expect(requests).toHaveLength(0)
      expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('Note edit mode is unavailable')
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 7 MID: TOCTOU. The refusal guards read availability synchronously, but
  // the request builder ran after the send's awaits. Discovery re-runs on every
  // `catalogRevision` bump and is not gated on `busy()`, so a mid-session server
  // downgrade could flip availability false while a send was parked — and the
  // builder would then withhold `mode`/`attachments` on a request the guard had
  // already admitted. That is the silent edit-as-memo masquerade again, arriving
  // through the await window instead of through the guard. Availability is now
  // captured ONCE at the top of send(), so the request is atomically either
  // fully extended or refused; an actually-old server rejects it loudly.
  test('a mid-send catalog flip cannot strip extensions from an already-admitted request', async () => {
    let releaseFirst!: () => void
    let releaseSecond!: () => void
    let releaseAttachmentRead!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const second = new Promise<void>((resolve) => { releaseSecond = resolve })
    const attachmentRead = new Promise<void>((resolve) => { releaseAttachmentRead = resolve })
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsGates: [{ wait: first, outcome: 'ok' }, { wait: second, outcome: 'graphql' }],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      releaseFirst()
      const model = () => host.querySelector<HTMLSelectElement>('select[aria-label="Agent model"]')!
      await waitFor(() => expect(model().disabled).toBe(false))

      // Both extensions are engaged against a healthy catalog. The staged file's
      // read is the hold: it parks the send between the guard and the builder,
      // which is exactly the window the flip has to lose.
      const noteEdit = host.querySelector<HTMLButtonElement>('button[aria-label="Edit note mode"]')!
      noteEdit.click()
      await waitFor(() => expect(noteEdit.getAttribute('aria-pressed')).toBe('true'))

      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))
      // Gate the read only AFTER staging: `validateComposerFiles` reads the file
      // too, and parking that would block the chip instead of the send.
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

      // Server is rolled back WHILE the send is parked on the attachment read.
      bumpCatalog()
      await settle()
      releaseSecond()
      await waitFor(() => expect(model().disabled).toBe(true))
      expect(requests).toHaveLength(0)

      releaseAttachmentRead()
      await waitFor(() => expect(requests).toHaveLength(1))
      // The guard admitted a fully-extended request, so a fully-extended request
      // is what goes out. Neither field may be silently dropped.
      expect(requests[0]).toMatchObject({ mode: 'edit', model: 'configured' })
      expect(requests[0]?.attachments).toHaveLength(1)
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 6 test-integrity MID. The capture at the top of `send()` holds TWO
  // values, and only `extensionsAvailable` was pinned: reverting the builder
  // argument to `retry ? retry.noteEdit : noteEdit()` left the whole gate green.
  // The hazard is the one the production comment names — the read-only effect
  // clears `noteEdit()` when the note stops being editable, and it is not gated
  // on `busy()`, so it can fire INSIDE the send's await window and strip `mode`
  // from a request the guard admitted as an edit. Same masquerade as the catalog
  // flip, reached through a different signal.
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

      // The staged file is only a way to park the send between the guard and the
      // builder; the assertion is about `mode`, not about attachments.
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

  // Step 7 MID, same root cause. The transport branch deliberately KEEPS the
  // staged files, so the chips still render while the catalog is unavailable.
  // A direct send withheld `attachments` entirely, and send()'s own setError('')
  // wiped the unreachable banner first, so nothing told the user their file was
  // dropped from a message they believed carried it.
  test('a direct send never silently drops staged attachments while the catalog is unavailable', async () => {
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsScript: ['ok', 'network', 'network', 'network'],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Earlier question'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      await waitFor(() => expect(picker.disabled).toBe(false))

      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))

      // Transport outage exhausts the budget; the chip is deliberately kept.
      bumpCatalog()
      await waitFor(() => expect(picker.disabled).toBe(true))
      expect(host.textContent).toContain('context.txt')

      const composer = host.querySelector('textarea')!
      composer.value = 'Use the attached file'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle(); await settle(); await settle()
      expect(requests).toHaveLength(0)
      expect(host.querySelector('.note-inline-error')?.textContent ?? '')
        .toContain('Attachments are unavailable')
      // The file is preserved, not dropped — the user can send once it recovers.
      expect(host.textContent).toContain('context.txt')
    } finally {
      dispose()
      host.remove()
    }
  })

  // The refusals guard the EFFECTIVE request, so both read the retry arm. A
  // retry never carries attachments (`attachmentInputs` is [] when retry is
  // set), and the Retry button is only disabled for EDIT turns — so a failed
  // MEMO turn is retryable during an outage. Reading attachments().length
  // instead of the retry arm would refuse that retry for chips it was never
  // going to send. This pins the arm that prevents the false refusal.
  test('a memo retry during an outage is not refused for chips it would never send', async () => {
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsScript: ['ok', 'network', 'network', 'network'],
        failedMemoTurn: true,
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
      })} />, host,
    )
    try {
      await waitFor(() => expect(host.textContent).toContain('Summarize the note'))
      const picker = host.querySelector<HTMLInputElement>('input[type="file"]')!
      await waitFor(() => expect(picker.disabled).toBe(false))

      const staged = new File(['context'], 'context.txt', { type: 'text/plain' })
      Object.defineProperty(picker, 'files', { configurable: true, value: [staged] })
      picker.dispatchEvent(new Event('change', { bubbles: true }))
      await waitFor(() => expect(host.textContent).toContain('context.txt'))

      bumpCatalog()
      await waitFor(() => expect(picker.disabled).toBe(true))

      const retry = [...host.querySelectorAll('button')].find((b) => b.textContent === 'Retry')!
      expect(retry.disabled).toBe(false)
      retry.click()
      await settle(); await settle(); await settle()
      expect(requests).toHaveLength(1)
      expect(requests[0]).not.toHaveProperty('attachments')
      expect(requests[0]).not.toHaveProperty('mode')
    } finally {
      dispose()
      host.remove()
    }
  })

  // Step 6 self-review MID, and the exhaustive application of mutation 15's
  // lesson. The builder takes FOUR `retry ? … : …` arms, and mutation 11 pins
  // only the GUARD's copy of the attachments one. Probing every arm found three
  // more survivors; this test kills the two that a single reachable scenario
  // distinguishes. A retry issued with chips staged and New chat pending must
  // still be a retry: it carries no attachments and posts back into the FAILED
  // TURN's conversation, not into a new one.
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

      // Catalog is HEALTHY here — that is what makes this distinct from the
      // outage retry test. With extensions available the builder would happily
      // put staged chips on the wire if the retry arm stopped withholding them.
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

  // Step 7 MID. The `!props.catalogAvailable` term was added to the note-edit
  // toggle's disabled/aria-disabled WITHOUT the `&& !props.noteEdit` escape the
  // adjacent canNoteEdit term already carries, so an ALREADY-PRESSED toggle went
  // hard-disabled the moment the catalog dropped. Every exit was then closed:
  // the toggle could not be released, memo-only refused with "Disable note edit
  // mode before enabling memo-only mode.", and the send refused because note
  // edit was still latched. The composer could send nothing at all.
  test('a latched note-edit toggle can still be released while the catalog is unavailable', async () => {
    let releaseFirst!: () => void
    let releaseSecond!: () => void
    const first = new Promise<void>((resolve) => { releaseFirst = resolve })
    const second = new Promise<void>((resolve) => { releaseSecond = resolve })
    let bumpCatalog!: () => void
    const requests: Array<Record<string, unknown>> = []
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(
      () => <MemoTab app={testStore(requests, [], {
        agentModelsGates: [{ wait: first, outcome: 'ok' }, { wait: second, outcome: 'graphql' }],
        bindBumpCatalog: (bump) => { bumpCatalog = bump },
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

      bumpCatalog()
      await settle()
      releaseSecond()
      await waitFor(() => expect(model().disabled).toBe(true))

      // The user must be able to back out of the mode they are now blocked on.
      expect(noteEdit.disabled).toBe(false)
      noteEdit.click()
      await waitFor(() => expect(noteEdit.getAttribute('aria-pressed')).toBe('false'))

      // And with note edit released, an ordinary memo send goes through.
      const composer = host.querySelector('textarea')!
      composer.value = 'Just answer, do not edit the note'
      composer.dispatchEvent(new Event('input', { bubbles: true }))
      composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
      await settle(); await settle(); await settle()
      expect(requests).toHaveLength(1)
      expect(requests[0]).not.toHaveProperty('mode')
    } finally {
      dispose()
      host.remove()
    }
  })
})

