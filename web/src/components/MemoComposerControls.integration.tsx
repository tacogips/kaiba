import { describe, expect, test } from 'vitest'
import { createComponent } from 'solid-js'
import { render } from 'solid-js/web'
import { MemoComposerControls } from './MemoTab'

describe('MemoComposerControls', () => {
  test('renders the selected memo-only, attachment, model, and submit controls accessibly', () => {
    const container = document.createElement('div')
    const dispose = render(() => createComponent(MemoComposerControls, {
      memoOnly: true,
      busy: false,
      draft: 'Capture this',
      attachments: [{ name: 'reference.txt' } as File],
      models: [{ modelId: 'configured', displayName: 'Configured model' }],
      selectedModel: 'configured',
      extensionsEnabled: true,
      catalogAvailable: true,
      onStageFiles: () => undefined,
      onToggleMemoOnly: () => undefined,
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
    expect(html).toContain('reference.txt')
    expect(html).toContain('title="Remove reference.txt"')
    expect(html).toContain('aria-label="Agent model"')
    expect(html).toContain('Configured model')
    expect(html).toContain('aria-label="Save memo"')
    dispose()
  })

  test('renders unavailable extensions as disabled while retaining the agent submit path', () => {
    const container = document.createElement('div')
    const dispose = render(() => createComponent(MemoComposerControls, {
      memoOnly: false,
      busy: false,
      draft: 'Ask',
      attachments: [],
      models: [],
      extensionsEnabled: false,
      catalogAvailable: false,
      onStageFiles: () => undefined,
      onToggleMemoOnly: () => undefined,
      onDraftChange: () => undefined,
      onRemoveAttachment: () => undefined,
      onModelChange: () => undefined,
      onSubmit: () => undefined,
    }), container)
    const html = container.innerHTML

    expect(html).toContain('title="Attachments require a newer server"')
    expect(html).toContain('aria-disabled="true"')
    expect(html).toContain('aria-label="Send message"')
    dispose()
  })
})
