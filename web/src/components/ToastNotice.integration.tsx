import { Show, createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { ToastNotice } from './ToastNotice'

function mount() {
  const dismiss = vi.fn()
  const retry = vi.fn()
  const [shown, setShown] = createSignal(true)
  const [message, setMessage] = createSignal('Could not load notes: requested note resource was not found')
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <><Show when={shown()}><ToastNotice message={message()} severity="error" onRetry={retry}
    onDismiss={() => { dismiss(); setShown(false) }} /></Show><button class="outside">Outside</button></>, host)
  return { host, dismiss, retry, setMessage, close: () => { dispose(); host.remove() } }
}

test('error toast exposes retry and manual dismissal and otherwise expires after eight seconds', async () => {
  vi.useFakeTimers(); const view = mount()
  try {
    expect(view.host.querySelector('[role="alert"]')?.textContent).toContain('Could not load notes')
    expect(view.host.querySelector('.app-toast-error')).not.toBeNull()
    view.host.querySelector<HTMLButtonElement>('[aria-label="Retry"]')!.click()
    expect(view.retry).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(7999); expect(view.dismiss).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1); expect(view.dismiss).toHaveBeenCalledTimes(1)
    expect(view.host.querySelector('.app-toast')).toBeNull()
  } finally { view.close(); vi.useRealTimers() }
})

test('manual close cancels the pending expiration', async () => {
  vi.useFakeTimers(); const view = mount()
  try {
    view.host.querySelector<HTMLButtonElement>('[aria-label="Dismiss message"]')!.click()
    expect(view.host.querySelector('.app-toast')).toBeNull()
    await vi.advanceTimersByTimeAsync(16000)
    expect(view.dismiss).toHaveBeenCalledTimes(1)
  } finally { view.close(); vi.useRealTimers() }
})

test('hover and keyboard focus pause expiration while the user reads or operates the toast', async () => {
  vi.useFakeTimers(); const view = mount()
  try {
    await vi.advanceTimersByTimeAsync(3000)
    const toast = view.host.querySelector<HTMLElement>('.app-toast')!
    toast.dispatchEvent(new Event('pointerenter'))
    await vi.advanceTimersByTimeAsync(10000); expect(view.dismiss).not.toHaveBeenCalled()
    view.host.querySelector<HTMLButtonElement>('[aria-label="Retry"]')!.focus()
    toast.dispatchEvent(new Event('pointerleave'))
    await vi.advanceTimersByTimeAsync(10000); expect(view.dismiss).not.toHaveBeenCalled()
    view.host.querySelector<HTMLButtonElement>('.outside')!.focus()
    await vi.advanceTimersByTimeAsync(4999); expect(view.dismiss).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1); expect(view.dismiss).toHaveBeenCalledTimes(1)
  } finally { view.close(); vi.useRealTimers() }
})

test('a replacement message receives its own full expiration time', async () => {
  vi.useFakeTimers(); const view = mount()
  try {
    await vi.advanceTimersByTimeAsync(7000)
    view.setMessage('Another error')
    await vi.advanceTimersByTimeAsync(7999); expect(view.dismiss).not.toHaveBeenCalled()
    expect(view.host.querySelector('.app-toast')?.textContent).toContain('Another error')
    await vi.advanceTimersByTimeAsync(1); expect(view.dismiss).toHaveBeenCalledTimes(1)
  } finally { view.close(); vi.useRealTimers() }
})
