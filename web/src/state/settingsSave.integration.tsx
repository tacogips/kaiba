import { createRoot } from 'solid-js'
import { afterEach, expect, test, vi } from 'vitest'
import { createSettingsSave } from './settingsSave'

afterEach(() => vi.useRealTimers())

function mount(save: (snapshot: string) => Promise<unknown>, onError = vi.fn()) {
  let dispose!: () => void
  const state = createRoot((cleanup) => { dispose = cleanup; return createSettingsSave(save, onError) })
  return { state, dispose, onError }
}

test('coalesces edits and serializes a newer snapshot behind an unresolved write', async () => {
  vi.useFakeTimers()
  const finishes: Array<() => void> = []
  const save = vi.fn(() => new Promise<void>((resolve) => finishes.push(resolve)))
  const view = mount(save)
  try {
    view.state.queue('first'); view.state.queue('second')
    expect(view.state.pending()).toBe(true)
    await vi.advanceTimersByTimeAsync(500)
    expect(save.mock.calls).toEqual([['second']])
    view.state.queue('third')
    await vi.advanceTimersByTimeAsync(500)
    expect(save).toHaveBeenCalledTimes(1)
    finishes[0]!(); await Promise.resolve()
    expect(save.mock.calls).toEqual([['second'], ['third']])
    expect(view.state.status()).toBe('saving')
    finishes[1]!(); await Promise.resolve()
    expect(view.state.status()).toBe('saved')
    expect(view.state.pending()).toBe(false)
  } finally { view.dispose() }
})

test('failed saves remain dirty and an explicit retry saves the latest preferences', async () => {
  vi.useFakeTimers()
  const save = vi.fn().mockRejectedValueOnce(new Error('Offline')).mockResolvedValueOnce(undefined)
  const view = mount(save)
  try {
    view.state.queue('preferences')
    await vi.advanceTimersByTimeAsync(500)
    expect(view.state.status()).toBe('error')
    expect(view.state.error()).toBe('Offline')
    expect(view.state.pending()).toBe(true)
    view.state.retry(); await Promise.resolve()
    expect(save.mock.calls).toEqual([['preferences'], ['preferences']])
    expect(view.state.status()).toBe('saved')
    expect(view.state.pending()).toBe(false)
  } finally { view.dispose() }
})

test('reset cancels deferred writes and old in-flight completion cannot clear a new session save', async () => {
  vi.useFakeTimers()
  const finishes: Array<() => void> = []
  const save = vi.fn(() => new Promise<void>((resolve) => finishes.push(resolve)))
  const view = mount(save)
  try {
    view.state.queue('cancelled'); view.state.reset()
    await vi.advanceTimersByTimeAsync(500)
    expect(save).not.toHaveBeenCalled()
    view.state.queue('old-session'); await vi.advanceTimersByTimeAsync(500)
    view.state.reset(); view.state.queue('new-session'); await vi.advanceTimersByTimeAsync(500)
    finishes[0]!(); await Promise.resolve()
    expect(view.state.pending()).toBe(true)
    finishes[1]!(); await Promise.resolve()
    expect(view.state.status()).toBe('saved')
    expect(view.onError).not.toHaveBeenCalled()
  } finally { view.dispose() }
})
