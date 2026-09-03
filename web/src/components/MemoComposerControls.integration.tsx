import { describe, expect, test } from 'vitest'
import { createComponent } from 'solid-js'
import { render } from 'solid-js/web'
import { MemoComposerControls } from './MemoTab'

describe('MemoComposerControls', () => {
  test('renders the selected memo-only, attachment, model, and submit controls accessibly', () => {
    const container = document.createElement('div')
    const dispose = render(() => createComponent(MemoComposerControls, {
      memoOnly: true,
      noteEdit: false,
      canNoteEdit: true,
      busy: false,
      draft: 'Capture this',
      attachments: [{ name: 'reference.txt' } as File],
      models: [{ modelId: 'configured', displayName: 'Configured model' }],
      selectedModel: 'configured',
      extensionsEnabled: true,
      onStageFiles: () => undefined,
      onToggleMemoOnly: () => undefined,
      onToggleNoteEdit: () => undefined,
      onDraftChange: () => undefined,
      onRemoveAttachment: () => undefined,
      onModelChange: () => undefined,
      onSubmit: () => undefined,
    }), container)
    const html = container.innerHTML

    expect(html).toContain('aria-label="Attach text files"')
    expect(html).toContain('aria-label="Memo only"')
    expect(html).toContain('aria-pressed="true"')
    expect(html).toContain('title="Memo only"')
    expect(html).toContain('aria-label="Edit note mode"')
    expect(html).toContain('title="Edit note mode"')
    expect(html).toContain('reference.txt')
    expect(html).toContain('title="Remove reference.txt"')
    expect(html).toContain('aria-label="Agent model"')
    expect(html).toContain('Configured model')
    expect(html).toContain('aria-label="Save memo"')
    dispose()
  })

  test('renders resting extension controls as disabled while retaining the agent submit path', () => {
    const container = document.createElement('div')
    const dispose = render(() => createComponent(MemoComposerControls, {
      memoOnly: false,
      noteEdit: false,
      canNoteEdit: false,
      busy: false,
      draft: 'Ask',
      attachments: [],
      models: [],
      extensionsEnabled: false,
      onStageFiles: () => undefined,
      onToggleMemoOnly: () => undefined,
      onToggleNoteEdit: () => undefined,
      onDraftChange: () => undefined,
      onRemoveAttachment: () => undefined,
      onModelChange: () => undefined,
      onSubmit: () => undefined,
    }), container)
    const html = container.innerHTML

    expect(html).toContain('title="Attach text files"')
    expect(html).toContain('aria-disabled="true"')
    expect(html).toContain('title="Note edit mode requires a writable note"')
    expect(html).toContain('aria-label="Send message"')
    dispose()
  })
})
