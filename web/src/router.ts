// Hash routing for the chatbook shell. Hash-based routes need no server rewrite
// and no router dependency; every route is a pure string transform so deep links
// can be restored, compared and tested without a DOM.

export type SearchScope = 'all' | 'notebook'
export type SearchMethod = 'agentic' | 'grep'

export type Route =
  | { kind: 'home' }
  | { kind: 'notebook'; notebookId: string; conversationId?: string }
  | { kind: 'note'; noteId: string; conversationId?: string }
  | { kind: 'board' }
  | { kind: 'search'; query: string; scope: SearchScope; method: SearchMethod; notebookId?: string }
  | { kind: 'config' }

export const homeRoute: Route = { kind: 'home' }

/** Keeps the route the reader should restore after a visit to the board, the
 * search results screen, or the config screen. */
export function rememberReaderRoute(route: Route, previous: Route = homeRoute): Route {
  return route.kind === 'board' || route.kind === 'search' || route.kind === 'config'
    ? previous
    : route
}

/** Parses `#/note/<id>?conv=<id>` and friends. Anything unrecognized — including
 * an empty hash on first load — resolves to the home route rather than failing. */
export function parseRoute(hash: string): Route {
  const raw = hash.startsWith('#') ? hash.slice(1) : hash
  const [pathPart = '', queryPart = ''] = splitOnce(raw, '?')
  const segments = pathPart.split('/').filter((segment) => segment.length > 0)
  const conversationId = readConversationId(queryPart)
  const [head, tail] = segments
  if (head === 'board') return { kind: 'board' }
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
      ...(notebookId ? { notebookId } : {}),
    }
  }
  if (head === 'notebook' && tail) {
    return { kind: 'notebook', notebookId: decodeSegment(tail), ...(conversationId ? { conversationId } : {}) }
  }
  if (head === 'note' && tail) {
    return { kind: 'note', noteId: decodeSegment(tail), ...(conversationId ? { conversationId } : {}) }
  }
  return homeRoute
}

export function formatRoute(route: Route): string {
  switch (route.kind) {
    case 'board':
      return '#/board'
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
      return `#/notebook/${encodeURIComponent(route.notebookId)}${conversationQuery(route.conversationId)}`
    case 'note':
      return `#/note/${encodeURIComponent(route.noteId)}${conversationQuery(route.conversationId)}`
    default:
      return '#/'
  }
}

export function routeNoteId(route: Route): string | undefined {
  return route.kind === 'note' ? route.noteId : undefined
}

export function routeNotebookId(route: Route): string | undefined {
  return route.kind === 'notebook' ? route.notebookId : undefined
}

export function routeConversationId(route: Route): string | undefined {
  return route.kind === 'note' || route.kind === 'notebook' ? route.conversationId : undefined
}

export function routesEqual(left: Route, right: Route): boolean {
  return formatRoute(left) === formatRoute(right)
}

/** Same route with a different open conversation; the home and board routes
 * carry no conversation so they are returned unchanged. */
export function withConversation(route: Route, conversationId?: string): Route {
  if (route.kind === 'note') {
    return { kind: 'note', noteId: route.noteId, ...(conversationId ? { conversationId } : {}) }
  }
  if (route.kind === 'notebook') {
    return { kind: 'notebook', notebookId: route.notebookId, ...(conversationId ? { conversationId } : {}) }
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

function conversationQuery(conversationId?: string): string {
  return conversationId ? `?conv=${encodeURIComponent(conversationId)}` : ''
}

function readConversationId(query: string): string | undefined {
  for (const entry of query.split('&')) {
    const [key = '', value = ''] = splitOnce(entry, '=')
    if (key !== 'conv' || value.length === 0) continue
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
