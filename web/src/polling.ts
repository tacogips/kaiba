import { createEffect, createSignal, onCleanup, type Accessor } from 'solid-js'

export type PollingStatus = 'on' | 'paused' | 'refreshing'

export interface PollingResource<T> {
  data: Accessor<T | undefined>
  error: Accessor<unknown>
  loading: Accessor<boolean>
  status: Accessor<PollingStatus>
  refresh: () => Promise<void>
}

export interface PollingEnvironment {
  hidden: () => boolean
  setInterval: (callback: () => void, intervalMs: number) => unknown
  clearInterval: (timer: unknown) => void
  addVisibilityListener: (listener: () => void) => void
  removeVisibilityListener: (listener: () => void) => void
}

export interface PollingState<T> {
  data?: T
  error?: unknown
  loading: boolean
  status: PollingStatus
}

export interface PollingController {
  contextChanged: () => void
  refresh: () => Promise<void>
  dispose: () => void
}

const browserPollingEnvironment: PollingEnvironment = {
  hidden: () => document.hidden,
  setInterval: (callback, intervalMs) => setInterval(callback, intervalMs),
  clearInterval: (timer) => clearInterval(timer as ReturnType<typeof setInterval>),
  addVisibilityListener: (listener) => document.addEventListener('visibilitychange', listener),
  removeVisibilityListener: (listener) => document.removeEventListener('visibilitychange', listener),
}

export function createPollingController<T>(
  contextKey: () => string | undefined,
  load: (signal: AbortSignal) => Promise<T>,
  publish: (state: PollingState<T>) => void,
  intervalMs = 5_000,
  environment: PollingEnvironment = browserPollingEnvironment,
): PollingController {
  let generation = 0
  let activeRequest: object | undefined
  let timer: unknown
  let controller: AbortController | undefined
  let disposed = false
  let state: PollingState<T> = {
    loading: false,
    status: environment.hidden() ? 'paused' : 'on',
  }

  const commit = (change: Partial<PollingState<T>>) => {
    state = { ...state, ...change }
    publish(state)
  }

  const stopTimer = () => {
    if (timer !== undefined) environment.clearInterval(timer)
    timer = undefined
  }

  const refresh = async () => {
    const key = contextKey()
    if (disposed || !key || activeRequest) return
    const requestGeneration = generation
    const requestToken = {}
    activeRequest = requestToken
    controller = new AbortController()
    commit({ loading: true, status: 'refreshing' })
    try {
      const value = await load(controller.signal)
      if (!disposed && requestGeneration === generation && key === contextKey()) {
        commit({ data: value, error: undefined })
      }
    } catch (requestError) {
      if (!disposed
        && requestGeneration === generation
        && key === contextKey()
        && !(requestError instanceof DOMException && requestError.name === 'AbortError')) {
        commit({ error: requestError })
      }
    } finally {
      if (!disposed && requestGeneration === generation && key === contextKey()) {
        commit({
          loading: false,
          status: environment.hidden() ? 'paused' : 'on',
        })
      }
      if (activeRequest === requestToken) activeRequest = undefined
    }
  }

  const startTimer = () => {
    stopTimer()
    if (!contextKey() || environment.hidden()) {
      commit({ status: 'paused' })
      return
    }
    if (!activeRequest) commit({ status: 'on' })
    timer = environment.setInterval(() => void refresh(), intervalMs)
  }

  const visibilityChanged = () => {
    if (environment.hidden()) {
      stopTimer()
      commit({ status: 'paused' })
    } else {
      startTimer()
      void refresh()
    }
  }

  environment.addVisibilityListener(visibilityChanged)

  return {
    contextChanged: () => {
      generation += 1
      controller?.abort()
      activeRequest = undefined
      commit({
        data: undefined,
        error: undefined,
        loading: false,
      })
      startTimer()
      if (!environment.hidden()) void refresh()
    },
    refresh,
    dispose: () => {
      disposed = true
      generation += 1
      controller?.abort()
      stopTimer()
      environment.removeVisibilityListener(visibilityChanged)
    },
  }
}

export function createPollingResource<T>(
  contextKey: Accessor<string | undefined>,
  load: (signal: AbortSignal) => Promise<T>,
  intervalMs = 5_000,
): PollingResource<T> {
  const [data, setData] = createSignal<T>()
  const [error, setError] = createSignal<unknown>()
  const [loading, setLoading] = createSignal(false)
  const [status, setStatus] = createSignal<PollingStatus>(document.hidden ? 'paused' : 'on')
  const controller = createPollingController(
    contextKey,
    load,
    (state) => {
      setData(() => state.data)
      setError(state.error)
      setLoading(state.loading)
      setStatus(state.status)
    },
    intervalMs,
  )

  createEffect(() => {
    contextKey()
    controller.contextChanged()
  })
  onCleanup(controller.dispose)

  return { data, error, loading, status, refresh: controller.refresh }
}

export function pollingStatusLabel(status: PollingStatus): string {
  if (status === 'paused') return 'Auto-refresh paused'
  if (status === 'refreshing') return 'Refreshing'
  return 'Auto-refresh on'
}
