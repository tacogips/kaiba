import { createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { MemoComposerControls } from './ChatComposer'

test('shared composer handles Enter, IME, models, file drop/paste, removal, and in-flight controls', async () => {
  const send = vi.fn()
  const stage = vi.fn()
  const remove = vi.fn()
  const model = vi.fn()
  const provider = vi.fn()
  const [busy, setBusy] = createSignal(false)
  const [generating, setGenerating] = createSignal(false)
  const host = document.createElement('div')
  document.body.append(host)
  const file = new File(['context'], 'context.txt', { type: 'text/plain' })
  const dispose = render(() => <MemoComposerControls memoOnly={false} noteEdit={false} canNoteEdit={false}
    busy={busy()} generating={generating()} draft="Hello" attachments={[file]} models={[{ modelId: 'small' }, { modelId: 'large' }]}
    providers={['server', 'codex']} selectedProvider="server" onProviderChange={provider}
    selectedModel="small" extensionsEnabled={!busy()} onStageFiles={stage} onRemoveAttachment={remove}
    onModelChange={model} onSubmit={send} onDraftChange={() => {}} onToggleMemoOnly={() => {}} onToggleNoteEdit={() => {}} />, host)
  try {
    const input = host.querySelector('textarea')!
    expect(input.hasAttribute('placeholder')).toBe(false)
    const key = (options: KeyboardEventInit = {}) => input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true, ...options }))
    key({ shiftKey: true }); key({ isComposing: true })
    expect(send).not.toHaveBeenCalled()
    key()
    expect(send).toHaveBeenCalledTimes(1)
    const providerSelector = host.querySelector<HTMLSelectElement>('[aria-label="Agent provider"]')!
    providerSelector.value = 'codex'
    providerSelector.dispatchEvent(new Event('input', { bubbles: true }))
    expect(provider).toHaveBeenCalledWith('codex')
    const selector = host.querySelector<HTMLSelectElement>('[aria-label="Agent model"]')!
    selector.value = 'large'
    selector.dispatchEvent(new Event('input', { bubbles: true }))
    expect(model).toHaveBeenCalledWith('large')
    host.querySelector<HTMLButtonElement>('[aria-label="Remove context.txt"]')!.click()
    expect(remove).toHaveBeenCalledWith(0)
    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(drop, 'dataTransfer', { value: { files: [file] } })
    host.querySelector('.memo-composer')!.dispatchEvent(drop)
    expect(stage).toHaveBeenCalledWith([file])
    const paste = new Event('paste', { bubbles: true, cancelable: true })
    Object.defineProperty(paste, 'clipboardData', { value: { files: [file] } })
    input.dispatchEvent(paste)
    expect(stage).toHaveBeenCalledTimes(2)
    setGenerating(true)
    key()
    expect(send).toHaveBeenCalledTimes(1)
    expect(input.disabled).toBe(false)
    setBusy(true)
    expect(input.disabled).toBe(true)
    expect(selector.disabled).toBe(true)
    expect(host.querySelector<HTMLButtonElement>('[aria-label="Remove context.txt"]')!.disabled).toBe(true)
  } finally { dispose(); host.remove() }
})
