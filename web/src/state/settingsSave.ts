import { createSignal, onCleanup } from 'solid-js'

export type SettingsSaveStatus = 'idle' | 'saving' | 'saved' | 'error'

/** Coalesce slider changes, serialize writes, and keep unsaved preferences
 * visible/protected until the newest snapshot is acknowledged. */
export function createSettingsSave(save: (snapshot: string) => Promise<unknown>, onError: (error: unknown) => void) {
  const [status, setStatus] = createSignal<SettingsSaveStatus>('idle')
  const [error, setError] = createSignal('')
  let timer: ReturnType<typeof setTimeout> | undefined
  let snapshot: string | undefined
  let revision = 0
  let generation = 0
  let running = false
  let disposed = false
  const cancelTimer = () => { if (timer) clearTimeout(timer); timer = undefined }
  const flush = async () => {
    if (running || disposed || snapshot === undefined) return
    cancelTimer()
    const value = snapshot, requested = revision, started = generation
    running = true
    setStatus('saving'); setError('')
    try {
      await save(value)
      if (started !== generation || disposed) return
      if (requested === revision) { setStatus('saved'); snapshot = undefined }
    } catch (failure) {
      if (started !== generation || disposed) return
      if (requested === revision) {
        setStatus('error')
        setError(failure instanceof Error ? failure.message : String(failure))
        onError(failure)
      }
    } finally {
      if (started === generation && !disposed) {
        running = false
        // A newer edit whose debounce elapsed while this write was in flight
        // must still be saved, including after an older write failed.
        if (revision !== requested && !timer) void flush()
      }
    }
  }
  const reset = () => {
    generation += 1; revision += 1; cancelTimer(); snapshot = undefined
    running = false; setError(''); setStatus('idle')
  }
  onCleanup(() => { reset(); disposed = true })
  return {
    status, error,
    pending: () => status() === 'saving' || status() === 'error',
    revision: () => revision,
    queue(value: string) {
      if (disposed) return
      snapshot = value; revision += 1; cancelTimer(); setStatus('saving'); setError('')
      timer = setTimeout(() => { timer = undefined; void flush() }, 500)
    },
    retry: () => { cancelTimer(); void flush() },
    reset,
  }
}
