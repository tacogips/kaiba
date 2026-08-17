import { noteId as asNoteId, notebookId as asNotebookId, tagId as asTagId } from './notes/ids'
import type { NoteId, NotebookId, TagId } from './notes/ids'
// Hash routing for the chatbook shell. Hash-based routes need no server rewrite
// and no router dependency; every route is a pure string transform so deep links
// can be restored, compared and tested without a DOM.

export type SearchScope = 'all' | 'notebook'
export type SearchMethod = 'agentic' | 'grep'

export type Route =
  | { kind: 'home' }
  | { kind: 'notebook'; notebookId: NotebookId; conversationId?: NotebookId; tagId?: TagId }
  | { kind: 'note'; noteId: NoteId; conversationId?: NotebookId; tagId?: TagId }
  | { kind: 'search'; query: string; scope: SearchScope; method: SearchMethod; notebookId?: NotebookId }
  | { kind: 'config' }

export const homeRoute: Route = { kind: 'home' }

/** Keeps the route the reader should restore after a visit to the search
 * results screen or the config screen. */
export function rememberReaderRoute(route: Route, previous: Route = homeRoute): Route {
  return route.kind === 'search' || route.kind === 'config'
    ? previous
    : route
}

/** Parses `#/note/<id>?conv=<id>` and friends. Anything unrecognized — including
 * an empty hash on first load — resolves to the home route rather than failing. */
export function parseRoute(hash: string): Route {
  const raw = hash.startsWith('#') ? hash.slice(1) : hash
  const [pathPart = '', queryPart = ''] = splitOnce(raw, '?')
  const segments = pathPart.split('/').filter((segment) => segment.length > 0)
  const rawConversationId = readQueryId(queryPart, 'conv')
  const rawTagId = readQueryId(queryPart, 'tag')
  // The URL is one of the two places raw text becomes an id (the other is the
  // GraphQL payload); everything downstream of here is typed.
  const conversationId = rawConversationId ? asNotebookId(rawConversationId) : undefined
  const tagId = rawTagId ? asTagId(rawTagId) : undefined
  const [head, tail] = segments
  if (head === 'config') return { kind: 'config' }
  if (head === 'search') {
    const parameters = readQueryParameters(queryPart)
    const query = parameters.q ?? ''
    const scope: SearchScope = parameters.scope === 'notebook' ? 'notebook' : 'all'
    const method: SearchMethod = parameters.method === 'grep' ? 'grep' : 'agentic'
    const notebookId = parameters.nb
    return {
      kind: 'search',
      query,
      scope,
      method,
      ...(notebookId ? { notebookId: asNotebookId(notebookId) } : {}),
    }
  }
  if (head === 'notebook' && tail) {
    return {
      kind: 'notebook',
      notebookId: asNotebookId(decodeSegment(tail)),
      ...(conversationId ? { conversationId } : {}),
      ...(tagId ? { tagId } : {}),
    }
  }
  if (head === 'note' && tail) {
    return {
      kind: 'note',
      noteId: asNoteId(decodeSegment(tail)),
      ...(conversationId ? { conversationId } : {}),
      ...(tagId ? { tagId } : {}),
    }
  }
  return homeRoute
}

export function formatRoute(route: Route): string {
  switch (route.kind) {
    case 'config':
      return '#/config'
    case 'search': {
      const parameters = [`q=${encodeURIComponent(route.query)}`]
      parameters.push(`scope=${route.scope}`)
      parameters.push(`method=${route.method}`)
      if (route.notebookId) parameters.push(`nb=${encodeURIComponent(route.notebookId)}`)
      return `#/search?${parameters.join('&')}`
    }
    case 'notebook':
      return `#/notebook/${encodeURIComponent(route.notebookId)}${selectionQuery(route.conversationId, route.tagId)}`
    case 'note':
      return `#/note/${encodeURIComponent(route.noteId)}${selectionQuery(route.conversationId, route.tagId)}`
    default:
      return '#/'
  }
}

/** Same route with a different open conversation; routes without a reader
 * selection carry no conversation and are returned unchanged. */
export function withConversation(route: Route, conversationId?: NotebookId): Route {
  if (route.kind === 'note') {
    return {
      kind: 'note',
      noteId: route.noteId,
      ...(conversationId ? { conversationId } : {}),
      ...(route.tagId ? { tagId: route.tagId } : {}),
    }
  }
  if (route.kind === 'notebook') {
    return {
      kind: 'notebook',
      notebookId: route.notebookId,
      ...(conversationId ? { conversationId } : {}),
      ...(route.tagId ? { tagId: route.tagId } : {}),
    }
  }
  return route
}

/** The tag whose detail pane the route opens (`?tag=<id>`). */
export function routeTagId(route: Route): TagId | undefined {
  return route.kind === 'note' || route.kind === 'notebook' ? route.tagId : undefined
}

/** Same route with the tag detail pane opened (or closed with undefined);
 * routes without a reader selection are returned unchanged. */
export function withTag(route: Route, tagId?: TagId): Route {
  if (route.kind === 'note') {
    return {
      kind: 'note',
      noteId: route.noteId,
      ...(route.conversationId ? { conversationId: route.conversationId } : {}),
      ...(tagId ? { tagId } : {}),
    }
  }
  if (route.kind === 'notebook') {
    return {
      kind: 'notebook',
      notebookId: route.notebookId,
      ...(route.conversationId ? { conversationId: route.conversationId } : {}),
      ...(tagId ? { tagId } : {}),
    }
  }
  return route
}

export interface RouterEnvironment {
  currentHash(): string
  setHash(value: string): void
  addListener(listener: () => void): void
  removeListener(listener: () => void): void
}

export function browserRouterEnvironment(): RouterEnvironment {
  return {
    currentHash: () => window.location.hash,
    setHash: (value) => { window.location.hash = value },
    addListener: (listener) => window.addEventListener('hashchange', listener),
    removeListener: (listener) => window.removeEventListener('hashchange', listener),
  }
}

/** Reports the current route and every later change; returns the unsubscribe. */
export function subscribeRoute(
  environment: RouterEnvironment,
  onRoute: (route: Route) => void,
): () => void {
  const listener = () => onRoute(parseRoute(environment.currentHash()))
  environment.addListener(listener)
  listener()
  return () => environment.removeListener(listener)
}

export function navigate(environment: RouterEnvironment, route: Route): void {
  const next = formatRoute(route)
  if (environment.currentHash() === next) return
  environment.setHash(next)
}

function selectionQuery(conversationId?: NotebookId, tagId?: TagId): string {
  const parameters: string[] = []
  if (conversationId) parameters.push(`conv=${encodeURIComponent(conversationId)}`)
  if (tagId) parameters.push(`tag=${encodeURIComponent(tagId)}`)
  return parameters.length === 0 ? '' : `?${parameters.join('&')}`
}

function readQueryId(query: string, name: string): string | undefined {
  for (const entry of query.split('&')) {
    const [key = '', value = ''] = splitOnce(entry, '=')
    if (key !== name || value.length === 0) continue
    const decoded = decodeSegment(value)
    if (decoded.length > 0) return decoded
  }
  return undefined
}

function readQueryParameters(query: string): Record<string, string> {
  const parameters: Record<string, string> = {}
  for (const entry of query.split('&')) {
    const [key = '', value = ''] = splitOnce(entry, '=')
    if (key.length === 0 || value.length === 0) continue
    parameters[decodeSegment(key)] = decodeSegment(value.replace(/\+/g, ' '))
  }
  return parameters
}

function splitOnce(value: string, separator: string): [string, string] {
  const index = value.indexOf(separator)
  return index < 0 ? [value, ''] : [value.slice(0, index), value.slice(index + separator.length)]
}

function decodeSegment(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    // A malformed escape must not break routing; the raw segment still selects.
    return value
  }
}
