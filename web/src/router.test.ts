import { describe, expect, test } from 'bun:test'
import {
  formatRoute,
  navigate,
  parseRoute,
  rememberReaderRoute,
  routeConversationId,
  routeNoteId,
  routeNotebookId,
  routesEqual,
  subscribeRoute,
  withConversation,
  type Route,
  type RouterEnvironment,
} from './router'

function environment(initialHash: string): RouterEnvironment & { hash: string; listeners: number } {
  const state = {
    hash: initialHash,
    listeners: 0,
    currentHash: () => state.hash,
    setHash: (value: string) => {
      state.hash = value
      for (const listener of registered) listener()
    },
    addListener: (listener: () => void) => {
      registered.add(listener)
      state.listeners = registered.size
    },
    removeListener: (listener: () => void) => {
      registered.delete(listener)
      state.listeners = registered.size
    },
  }
  const registered = new Set<() => void>()
  return state
}

describe('route parsing', () => {
  test('resolves the documented routes', () => {
    expect(parseRoute('#/')).toEqual({ kind: 'home' })
    expect(parseRoute('#/notebook/nb-1')).toEqual({ kind: 'notebook', notebookId: 'nb-1' })
    expect(parseRoute('#/note/note-1')).toEqual({ kind: 'note', noteId: 'note-1' })
    expect(parseRoute('#/board')).toEqual({ kind: 'board' })
  })

  test('reads the open conversation from the query', () => {
    expect(parseRoute('#/note/note-1?conv=conv-9'))
      .toEqual({ kind: 'note', noteId: 'note-1', conversationId: 'conv-9' })
    expect(parseRoute('#/notebook/nb-1?other=1&conv=conv-9'))
      .toEqual({ kind: 'notebook', notebookId: 'nb-1', conversationId: 'conv-9' })
    expect(parseRoute('#/note/note-1?conv=')).toEqual({ kind: 'note', noteId: 'note-1' })
  })

  test('parses the search route with scope, method and notebook pin', () => {
    expect(parseRoute('#/search?q=alpha%20beta&scope=notebook&method=grep&nb=nb-1'))
      .toEqual({ kind: 'search', query: 'alpha beta', scope: 'notebook', method: 'grep', notebookId: 'nb-1' })
    // Defaults: all notebooks, agentic method.
    expect(parseRoute('#/search?q=alpha'))
      .toEqual({ kind: 'search', query: 'alpha', scope: 'all', method: 'agentic' })
    expect(parseRoute('#/search?q=a+b'))
      .toEqual({ kind: 'search', query: 'a b', scope: 'all', method: 'agentic' })
  })

  test('search routes round-trip through format and parse', () => {
    const route: Route = { kind: 'search', query: 'ヴェネツィア 貿易', scope: 'notebook', method: 'agentic', notebookId: 'nb/9' }
    expect(parseRoute(formatRoute(route))).toEqual(route)
  })

  test('parses the config route', () => {
    expect(parseRoute('#/config')).toEqual({ kind: 'config' })
    expect(parseRoute(formatRoute({ kind: 'config' }))).toEqual({ kind: 'config' })
  })

  test('falls back to home for empty, partial and unknown hashes', () => {
    expect(parseRoute('')).toEqual({ kind: 'home' })
    expect(parseRoute('#')).toEqual({ kind: 'home' })
    expect(parseRoute('#/note')).toEqual({ kind: 'home' })
    expect(parseRoute('#/unknown/thing')).toEqual({ kind: 'home' })
  })

  test('decodes escaped ids and survives a malformed escape', () => {
    expect(parseRoute('#/note/note%2F1')).toEqual({ kind: 'note', noteId: 'note/1' })
    expect(parseRoute('#/note/note%ZZ')).toEqual({ kind: 'note', noteId: 'note%ZZ' })
  })

  test('a hash without the leading marker parses the same way', () => {
    expect(parseRoute('/note/note-1')).toEqual({ kind: 'note', noteId: 'note-1' })
  })
})

describe('route formatting', () => {
  test('round-trips every route', () => {
    const routes: Route[] = [
      { kind: 'home' },
      { kind: 'board' },
      { kind: 'notebook', notebookId: 'nb-1' },
      { kind: 'note', noteId: 'note-1' },
      { kind: 'note', noteId: 'note/1', conversationId: 'conv 9' },
    ]
    for (const route of routes) expect(parseRoute(formatRoute(route))).toEqual(route)
  })

  test('exposes selection accessors and equality', () => {
    const route = parseRoute('#/note/note-1?conv=conv-9')
    expect(routeNoteId(route)).toBe('note-1')
    expect(routeNotebookId(route)).toBeUndefined()
    expect(routeConversationId(route)).toBe('conv-9')
    expect(routesEqual(route, parseRoute('#/note/note-1?conv=conv-9'))).toBe(true)
    expect(routesEqual(route, parseRoute('#/note/note-1'))).toBe(false)
  })

  test('replaces and clears the open conversation', () => {
    const route = parseRoute('#/note/note-1?conv=conv-9')
    expect(formatRoute(withConversation(route, 'conv-3'))).toBe('#/note/note-1?conv=conv-3')
    expect(formatRoute(withConversation(route, undefined))).toBe('#/note/note-1')
    expect(withConversation({ kind: 'home' }, 'conv-3')).toEqual({ kind: 'home' })
  })
})

describe('reader return route', () => {
  test('preserves the last reader route while visiting the board', () => {
    const note: Route = { kind: 'note', noteId: 'note-1', conversationId: 'conv-9' }
    const remembered = rememberReaderRoute(note)
    expect(rememberReaderRoute({ kind: 'board' }, remembered)).toEqual(note)
  })

  test('falls back to home when the board was opened directly', () => {
    expect(rememberReaderRoute({ kind: 'board' })).toEqual({ kind: 'home' })
  })
})

describe('route subscription', () => {
  test('reports the current route immediately and on every change', () => {
    const env = environment('#/note/note-1')
    const seen: Route[] = []
    const unsubscribe = subscribeRoute(env, (route) => seen.push(route))
    navigate(env, { kind: 'notebook', notebookId: 'nb-2' })
    expect(seen).toEqual([
      { kind: 'note', noteId: 'note-1' },
      { kind: 'notebook', notebookId: 'nb-2' },
    ])
    unsubscribe()
    expect(env.listeners).toBe(0)
  })

  test('navigating to the current route does not re-enter', () => {
    const env = environment('#/note/note-1')
    const seen: Route[] = []
    subscribeRoute(env, (route) => seen.push(route))
    navigate(env, { kind: 'note', noteId: 'note-1' })
    expect(seen).toHaveLength(1)
  })
})
