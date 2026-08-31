import { notebookId as asNotebookId } from './ids'
import { describe, expect, test } from 'bun:test'
import { subscribeNoteEvents, type NoteChangeEvent } from './events'

interface PollCall {
  url: string
  headers: Record<string, string>
}

type QueuedResponse =
  | { ok: true; body: unknown }
  | { ok: false; status: number }
  | { throws: true }

/**
 * Drives the long-poll loop one queued response at a time. Once the queue
 * drains the loop parks on a never-settling promise, which is what the real
 * server does while it holds a poll open, and keeps each test deterministic.
 */
function makeFetchImpl(responses: QueuedResponse[]) {
  const calls: PollCall[] = []
  let index = 0
  const fetchImpl = async (url: string, init: RequestInit): Promise<Response> => {
    calls.push({ url, headers: (init.headers ?? {}) as Record<string, string> })
    const next = responses[index]
    index += 1
    if (!next) return await new Promise<Response>(() => {})
    if ('throws' in next) throw new Error('network down')
    if (!next.ok) return { ok: false, status: next.status } as Response
    return { ok: true, json: async () => next.body } as Response
  }
  return { fetchImpl: fetchImpl as unknown as typeof fetch, calls }
}

const settle = (ms = 25) => new Promise((resolve) => setTimeout(resolve, ms))

describe('subscribeNoteEvents', () => {
  test('forwards decoded events to the subscriber', async () => {
    const events: NoteChangeEvent[] = []
    const { fetchImpl } = makeFetchImpl([
      {
        ok: true,
        body: {
          revision: 'cursor-3',
          events: [
            { kind: 'notebook-read-only', notebookId: asNotebookId('nb-1'), tagNames: ['proj/alpha'] },
            { kind: 'notebook-tags', notebookId: null, tagNames: [] },
          ],
        },
      },
    ])
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({ Authorization: 'Bearer token' }),
      onEvent: (event) => events.push(event),
      onConnect: () => {},
      fetchImpl,
    })
    await settle()
    unsubscribe()

    expect(events.map((event) => event.kind)).toEqual(['notebook-read-only', 'notebook-tags'])
    expect(events[0]?.tagNames).toEqual(['proj/alpha'])
    expect(events[0]?.notebookId).toBe(asNotebookId('nb-1'))
  })

  test('threads the revision from each response into the next poll', async () => {
    const { fetchImpl, calls } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-4', events: [] } },
      { ok: true, body: { revision: 'cursor-9', events: [] } },
    ])
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({ Authorization: 'Bearer token' }),
      onEvent: () => {},
      onConnect: () => {},
      fetchImpl,
    })
    await settle()
    unsubscribe()

    expect(calls[0]?.url).toContain('since=0')
    expect(calls[1]?.url).toContain('since=cursor-4')
    expect(calls[2]?.url).toContain('since=cursor-9')
    expect(calls[0]?.url).toContain('timeoutMs=25000')
    expect(calls[0]?.headers.Authorization).toBe('Bearer token')
  })

  test('replays the current batch when an event callback fails', async () => {
    const { fetchImpl, calls } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-4', events: [{ kind: 'note-created' }] } },
      { ok: true, body: { revision: 'cursor-4', events: [{ kind: 'note-created' }] } },
    ])
    const events: NoteChangeEvent[] = []
    let remainingFailures = 1
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onConnect: () => {},
      onEvent: (event) => {
        if (remainingFailures > 0) {
          remainingFailures -= 1
          throw new Error('subscriber failed before completing the batch')
        }
        events.push(event)
      },
      fetchImpl,
      reconnectDelayMs: 1,
    })
    await settle(50)
    unsubscribe()

    expect(events.map((event) => event.kind)).toEqual(['note-created'])
    expect(calls[0]?.url).toContain('since=0')
    expect(calls[1]?.url).toContain('since=0')
    expect(calls[2]?.url).toContain('since=cursor-4')
  })

  test('calls onConnect once per connection, not once per poll', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-1', events: [] } },
      { ok: true, body: { revision: 'cursor-2', events: [] } },
    ])
    let connects = 0
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onEvent: () => {},
      onConnect: () => { connects += 1 },
      fetchImpl,
    })
    await settle()
    unsubscribe()

    expect(connects).toBe(1)
  })

  test('refreshes when the server resets an opaque cursor', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-1', events: [] } },
      { ok: true, body: { revision: 'cursor-2', resync: true, events: [] } },
    ])
    let connects = 0
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onEvent: () => {},
      onConnect: () => { connects += 1 },
      fetchImpl,
    })
    await settle()
    unsubscribe()

    expect(connects).toBe(2)
  })

  test('calls onConnect again after a failure interrupts the loop', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-1', events: [] } },
      { throws: true },
      { ok: true, body: { revision: 'cursor-2', events: [] } },
    ])
    let connects = 0
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onEvent: () => {},
      onConnect: () => { connects += 1 },
      fetchImpl,
      reconnectDelayMs: 1,
    })
    await settle(50)
    unsubscribe()

    expect(connects).toBe(2)
  })

  test('reports unavailability once per outage after five consecutive failures', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: false, status: 503 },
      { ok: false, status: 503 },
      { ok: false, status: 503 },
      { ok: false, status: 503 },
      { ok: false, status: 503 },
      { ok: false, status: 503 },
      { ok: false, status: 503 },
    ])
    let unavailable = 0
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onEvent: () => {},
      onConnect: () => {},
      onUnavailable: () => { unavailable += 1 },
      fetchImpl,
      reconnectDelayMs: 1,
    })
    await settle(200)
    unsubscribe()

    expect(unavailable).toBe(1)
  })

  test('stops polling after unsubscribe', async () => {
    const { fetchImpl, calls } = makeFetchImpl([
      { ok: true, body: { revision: 'cursor-1', events: [] } },
      { ok: true, body: { revision: 'cursor-2', events: [] } },
    ])
    const unsubscribe = subscribeNoteEvents({
      headers: () => ({}),
      onEvent: () => {},
      onConnect: () => {},
      fetchImpl,
    })
    await settle()
    const seen = calls.length
    unsubscribe()
    await settle()

    expect(calls.length).toBe(seen)
  })
})
