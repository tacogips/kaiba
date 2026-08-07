import { describe, expect, test } from 'bun:test'
import { eventAffectsScope, subscribeNoteEvents, type NoteChangeEvent } from './events'

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
          revision: 3,
          events: [
            { kind: 'notebook-progress', notebookId: 'nb-1', tagNames: ['proj/alpha'] },
            { kind: 'status-sets', notebookId: null, tagNames: [] },
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

    expect(events.map((event) => event.kind)).toEqual(['notebook-progress', 'status-sets'])
    expect(events[0]?.tagNames).toEqual(['proj/alpha'])
    expect(events[0]?.notebookId).toBe('nb-1')
  })

  test('threads the revision from each response into the next poll', async () => {
    const { fetchImpl, calls } = makeFetchImpl([
      { ok: true, body: { revision: 4, events: [] } },
      { ok: true, body: { revision: 9, events: [] } },
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
    expect(calls[1]?.url).toContain('since=4')
    expect(calls[2]?.url).toContain('since=9')
    expect(calls[0]?.url).toContain('timeoutMs=25000')
    expect(calls[0]?.headers.Authorization).toBe('Bearer token')
  })

  test('calls onConnect once per connection, not once per poll', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: true, body: { revision: 1, events: [] } },
      { ok: true, body: { revision: 2, events: [] } },
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

  test('calls onConnect again after a failure interrupts the loop', async () => {
    const { fetchImpl } = makeFetchImpl([
      { ok: true, body: { revision: 1, events: [] } },
      { throws: true },
      { ok: true, body: { revision: 2, events: [] } },
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
      { ok: true, body: { revision: 1, events: [] } },
      { ok: true, body: { revision: 2, events: [] } },
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

describe('eventAffectsScope', () => {
  test('treats an empty tagNames list as unknown scope affecting every board', () => {
    expect(eventAffectsScope({ kind: 'status-sets', tagNames: [] }, ['proj/alpha'])).toBe(true)
    expect(eventAffectsScope({ kind: 'status-sets' }, ['proj/alpha'])).toBe(true)
    expect(eventAffectsScope({ kind: 'status-sets', tagNames: null }, ['proj/alpha'])).toBe(true)
  })

  test('matches when any event tag is in the board scope', () => {
    const event: NoteChangeEvent = { kind: 'notebook-progress', tagNames: ['proj/beta'] }
    expect(eventAffectsScope(event, ['proj/alpha', 'proj/beta'])).toBe(true)
  })

  test('rejects an event scoped entirely outside the board', () => {
    const event: NoteChangeEvent = { kind: 'notebook-progress', tagNames: ['proj/gamma'] }
    expect(eventAffectsScope(event, ['proj/alpha'])).toBe(false)
  })

  test('treats an unscoped board as accepting every event', () => {
    const event: NoteChangeEvent = { kind: 'notebook-progress', tagNames: ['proj/gamma'] }
    expect(eventAffectsScope(event, [])).toBe(true)
  })
})
