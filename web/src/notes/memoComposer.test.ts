import { describe, expect, test } from 'bun:test'
import {
  agentComposerExtensionsEnabled,
  buildAgentChatComposerRequest,
  composerAttachmentMediaType,
  canEnableMemoOnly,
  canEnableNoteEdit,
  composerKeyDownAction,
  composerSubmitKind,
  composerShouldSubmit,
  memoOnlyControlAttributes,
  memoOnlyToggleResult,
  handleComposerKeyDown,
  normalizeSelectedAgentModel,
  noteEditControlAttributes,
  noteEditToggleResult,
  removeComposerAttachment,
  resetComposerForNewChat,
  validateComposerFiles,
} from './memoComposer'

describe('memo composer state', () => {
  test('Enter submits but Shift+Enter and IME composition do not', () => {
    expect(composerShouldSubmit({ key: 'Enter', shiftKey: false, isComposing: false })).toBe(true)
    expect(composerShouldSubmit({ key: 'Enter', shiftKey: true, isComposing: false })).toBe(false)
    expect(composerShouldSubmit({ key: 'Enter', shiftKey: false, isComposing: true })).toBe(false)
    expect(composerKeyDownAction(
      { key: 'Enter', shiftKey: false, isComposing: false }, { busy: false, hasDraft: true },
    )).toBe('submit')
    expect(composerKeyDownAction(
      { key: 'Enter', shiftKey: false, isComposing: false }, { busy: true, hasDraft: true },
    )).toBe('none')
    expect(composerKeyDownAction(
      { key: 'Enter', shiftKey: false, isComposing: false }, { busy: false, hasDraft: false },
    )).toBe('none')
    let prevented = 0
    let submitted = 0
    const event = {
      key: 'Enter', shiftKey: false, isComposing: false,
      preventDefault: () => { prevented += 1 },
    }
    expect(handleComposerKeyDown(event, { busy: false, hasDraft: true }, () => { submitted += 1 })).toBe(true)
    expect({ prevented, submitted }).toEqual({ prevented: 1, submitted: 1 })
    expect(handleComposerKeyDown(
      { ...event, isComposing: true }, { busy: false, hasDraft: true }, () => { submitted += 1 },
    )).toBe(false)
    expect({ prevented, submitted }).toEqual({ prevented: 1, submitted: 1 })
  })

  test('rejects unsafe, empty, duplicate, unsupported, and non-UTF-8 files', async () => {
    expect((await validateComposerFiles([new File(['x'], '../x.txt', { type: 'text/plain' })])).accepted).toBe(false)
    expect((await validateComposerFiles([new File([], 'empty.txt', { type: 'text/plain' })])).accepted).toBe(false)
    expect((await validateComposerFiles([new File(['x'], 'script.html', { type: 'text/html' })])).accepted).toBe(false)
    const file = new File(['x'], 'x.txt', { type: 'text/plain' })
    expect((await validateComposerFiles([file, file])).accepted).toBe(false)
    expect((await validateComposerFiles([new File([new Uint8Array([0xFF])], 'bad.txt', { type: 'text/plain' })])).accepted).toBe(false)
    expect((await validateComposerFiles([new File(['x'], `${'名'.repeat(128)}.txt`, { type: 'text/plain' })])).accepted).toBe(false)
    expect((await validateComposerFiles(Array.from({ length: 5 }, (_, index) =>
      new File(['x'], `${index}.txt`, { type: 'text/plain' })))).accepted).toBe(false)
    expect((await validateComposerFiles([new File([new Uint8Array(1_048_577)], 'large.txt', { type: 'text/plain' })])).accepted).toBe(false)
    expect((await validateComposerFiles([new File(['x'], 'fallback.txt', { type: 'application/octet-stream' })])).accepted).toBe(true)
    expect((await validateComposerFiles([new File(['x'], 'fallback.md', { type: '' })])).accepted).toBe(true)
    expect(composerAttachmentMediaType({ name: 'fallback.txt', type: 'binary/octet-stream' } as File)).toBe('text/plain')
  })

  test('keeps model and attachment extensions disabled together for old servers', () => {
    expect(agentComposerExtensionsEnabled(false, false, false)).toBe(false)
    expect(agentComposerExtensionsEnabled(true, true, false)).toBe(false)
    expect(agentComposerExtensionsEnabled(true, false, true)).toBe(false)
    expect(agentComposerExtensionsEnabled(true, false, false)).toBe(true)
    expect(canEnableMemoOnly(0)).toBe(true)
    expect(canEnableMemoOnly(1)).toBe(false)
  })

  test('new chat clears transient composer state and attachment removal is deterministic', () => {
    expect(resetComposerForNewChat<File>()).toEqual({
      newConversation: true,
      draft: '',
      attachments: [],
      error: '',
    })
    expect(removeComposerAttachment(['first', 'second'], 0)).toEqual(['second'])
  })

  test('new chat request omits existing conversation while preserving model and attachment contract', () => {
    const options = {
      subject: { kind: 'note' as const, id: 'note-1' },
      conversations: [{ notebookId: 'conversation-old', title: 'Old', updatedAt: '2026-08-13T00:00:00Z', turnCount: 2, subjectNoteId: 'note-1' }],
      userMarkdown: '  Ask this  ',
      idempotencyKey: 'turn-1',
      extensionsAvailable: true,
      selectedModel: 'openai/gpt-5-mini',
      attachments: [{ contentBase64: 'eA==', mediaType: 'text/plain', originalFilename: 'x.txt' }],
    }
    expect(buildAgentChatComposerRequest({ ...options, newConversation: true })).toEqual({
      subjectNoteId: 'note-1', userMarkdown: 'Ask this', idempotencyKey: 'turn-1',
      model: 'openai/gpt-5-mini', attachments: options.attachments,
    })
    expect(buildAgentChatComposerRequest({ ...options, newConversation: false }).conversationNotebookId)
      .toBe('conversation-old')
    expect(buildAgentChatComposerRequest({
      ...options, newConversation: false, activeConversationId: 'conversation-new',
    }).conversationNotebookId).toBe('conversation-new')
  })

  test('memo-only stays on the memo path and old-server requests omit extension fields', () => {
    expect(composerSubmitKind(true)).toBe('memo')
    expect(composerSubmitKind(false)).toBe('agent')
    const request = buildAgentChatComposerRequest({
      subject: { kind: 'notebook', id: 'notebook-1' }, conversations: [], newConversation: false,
      userMarkdown: 'Message', idempotencyKey: 'turn-2', extensionsAvailable: false,
      selectedModel: 'saved-model', attachments: [{ contentBase64: 'eA==', mediaType: 'text/plain', originalFilename: 'x.txt' }],
    })
    expect(request).toEqual({ subjectNotebookId: 'notebook-1', userMarkdown: 'Message', idempotencyKey: 'turn-2' })
  })

  test('memo-only control exposes its selected accessible state and tooltip', () => {
    expect(memoOnlyControlAttributes(true)).toEqual({ ariaPressed: true, ariaLabel: 'Memo only', title: 'Memo only' })
    expect(memoOnlyControlAttributes(false).ariaPressed).toBe(false)
    expect(memoOnlyToggleResult(false, 1)).toEqual({
      selected: false,
      error: 'Remove attached files before enabling memo-only mode.',
    })
    expect(memoOnlyToggleResult(false, 0)).toEqual({ selected: true, error: '' })
  })

  test('note edit mode requires a writable note subject matching the loaded note', () => {
    const subject = { kind: 'note' as const, id: 'note-1' }
    const note = { noteId: 'note-1', readOnly: false }
    const notebook = { readOnly: false }
    expect(canEnableNoteEdit(subject, note, notebook)).toBe(true)
    expect(canEnableNoteEdit(undefined, note, notebook)).toBe(false)
    expect(canEnableNoteEdit({ kind: 'notebook', id: 'notebook-1' }, note, notebook)).toBe(false)
    expect(canEnableNoteEdit(subject, { noteId: 'other', readOnly: false }, notebook)).toBe(false)
    expect(canEnableNoteEdit(subject, undefined, notebook)).toBe(false)
    expect(canEnableNoteEdit(subject, { noteId: 'note-1', readOnly: true }, notebook)).toBe(false)
    // Imported documents lock the notebook, not each page.
    expect(canEnableNoteEdit(subject, note, { readOnly: true })).toBe(false)
    expect(canEnableNoteEdit(subject, note, undefined)).toBe(false)
  })

  test('note edit toggle blocks unwritable subjects and memo-only conflicts symmetrically', () => {
    expect(noteEditToggleResult(false, { canEdit: true, memoOnly: false })).toEqual({ selected: true, error: '' })
    expect(noteEditToggleResult(true, { canEdit: true, memoOnly: false })).toEqual({ selected: false, error: '' })
    expect(noteEditToggleResult(false, { canEdit: false, memoOnly: false })).toEqual({
      selected: false,
      error: 'Note edit mode requires a writable note.',
    })
    expect(noteEditToggleResult(false, { canEdit: true, memoOnly: true })).toEqual({
      selected: false,
      error: 'Disable memo-only mode before enabling note edit mode.',
    })
    expect(memoOnlyToggleResult(false, 0, true)).toEqual({
      selected: false,
      error: 'Disable note edit mode before enabling memo-only mode.',
    })
    expect(noteEditControlAttributes(true)).toEqual({
      ariaPressed: true, ariaLabel: 'Edit note mode', title: 'Edit note mode',
    })
  })

  test('note edit sends mode "edit" only on servers with composer extensions', () => {
    const options = {
      subject: { kind: 'note' as const, id: 'note-1' },
      conversations: [],
      newConversation: false,
      userMarkdown: 'Reword the intro',
      idempotencyKey: 'turn-3',
      attachments: [],
    }
    expect(buildAgentChatComposerRequest({ ...options, extensionsAvailable: true, noteEdit: true }).mode)
      .toBe('edit')
    expect(buildAgentChatComposerRequest({ ...options, extensionsAvailable: true, noteEdit: false }).mode)
      .toBeUndefined()
    // An old server would silently ignore the field and answer as a memo,
    // which must never masquerade as an applied edit.
    expect(buildAgentChatComposerRequest({ ...options, extensionsAvailable: false, noteEdit: true }).mode)
      .toBeUndefined()
  })

  test('normalizes persisted model selection against the current catalog fallback', () => {
    const models = [{ modelId: 'configured' }, { modelId: 'available' }]
    expect(normalizeSelectedAgentModel('available', models, 'configured')).toBe('available')
    expect(normalizeSelectedAgentModel('stale', models, 'configured')).toBe('configured')
    expect(normalizeSelectedAgentModel(undefined, [], undefined)).toBeUndefined()
  })
})
