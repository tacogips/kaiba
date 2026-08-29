import type { NotebookId } from './ids'
import { serverRequest } from './serverEndpoint'
export interface NoteChangeEvent {
  kind: string
  notebookId?: NotebookId | null
  tagNames?: string[] | null
}

export interface NoteEventStreamOptions {
  /** Returns headers for the poll request (bearer / app headers). */
  headers(): Record<string, string>
  /** Called for every decoded note-change event. */
  onEvent(event: NoteChangeEvent): void
  /** Called on (re)connect; the subscriber should refresh once. */
  onConnect(): void
  /** Called when the feed is unavailable and retries are exhausted for now. */
  onUnavailable?(): void
  fetchImpl?: typeof fetch
  /** Base reconnect delay in ms (doubles up to 30s). */
  reconnectDelayMs?: number
}

interface NoteEventPollResponse {
  revision: number
  events: NoteChangeEvent[]
}

const POLL_TIMEOUT_MS = 25_000
const FAILURES_BEFORE_UNAVAILABLE = 5

/**
 * Subscribes to the `/note/events` long-poll feed. Browser deployments use
 * same-origin fetch; native apps resolve the path against their configured
 * server. The server holds
 * each request open until the store's revision passes the one we last saw, so
 * updates arrive with push latency over a plain request/response transport.
 * Events only schedule refreshes on the caller's side; an unavailable feed
 * degrades to the caller's manual refresh behavior.
 */
export function subscribeNoteEvents(options: NoteEventStreamOptions): () => void {
  const fetchImpl = options.fetchImpl ?? serverRequest
  const baseDelay = options.reconnectDelayMs ?? 1000
  let closed = false
  let connected = false
  let failures = 0
  let reportedUnavailable = false
  let revision = 0
  let abort = new AbortController()

  const run = async (): Promise<void> => {
    while (!closed) {
      abort = new AbortController()
      try {
        const response = await fetchImpl(
          `/note/events?since=${revision}&timeoutMs=${POLL_TIMEOUT_MS}`,
          {
            method: 'GET',
            credentials: 'same-origin',
            headers: { Accept: 'application/json', ...options.headers() },
            signal: abort.signal,
          },
        )
        if (!response.ok) {
          throw new Error(`note event feed unavailable (${response.status})`)
        }
        const payload = (await response.json()) as Partial<NoteEventPollResponse>
        if (typeof payload.revision !== 'number') {
          throw new Error('note event feed returned a malformed payload')
        }
        if (closed) return
        revision = payload.revision
        failures = 0
        reportedUnavailable = false
        // Only on (re)connect, never per poll: the subscriber treats onConnect
        // as "you may have missed events, refresh once".
        if (!connected) {
          connected = true
          options.onConnect()
        }
        for (const event of payload.events ?? []) {
          if (typeof event?.kind === 'string') options.onEvent(event)
        }
        continue
      } catch {
        if (closed) return
      }
      connected = false
      failures += 1
      if (failures >= FAILURES_BEFORE_UNAVAILABLE && !reportedUnavailable) {
        reportedUnavailable = true
        options.onUnavailable?.()
      }
      const delay = Math.min(baseDelay * 2 ** Math.min(failures, 5), 30_000)
      await new Promise((resolve) => setTimeout(resolve, delay))
    }
  }
  void run()

  return () => {
    closed = true
    abort.abort()
  }
}
