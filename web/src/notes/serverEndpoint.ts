export const serverEndpointStorageKey = 'kaiba-server-endpoint'
export const defaultServerEndpoint = 'http://127.0.0.1:8787'

export interface EndpointStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

interface TauriGlobal {
  __TAURI_INTERNALS__?: unknown
}

export function isTauriRuntime(global: object = globalThis): boolean {
  return '__TAURI_INTERNALS__' in (global as TauriGlobal)
}

export function normalizeServerEndpoint(value: string): string {
  const trimmed = value.trim()
  if (!trimmed) throw new Error('A kaiba server URL is required.')

  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    throw new Error('Enter a complete server URL, such as http://192.168.1.20:8787.')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('The server URL must use HTTP or HTTPS.')
  }
  if (url.username || url.password) throw new Error('The server URL cannot contain credentials.')
  if (url.search || url.hash) throw new Error('The server URL cannot contain a query or fragment.')
  if (url.pathname !== '/' && url.pathname !== '') {
    throw new Error('The server URL must not contain a path.')
  }
  return url.toString().replace(/\/$/, '')
}

export function readServerEndpoint(storage?: EndpointStorage): string {
  const resolvedStorage = storage ?? availableEndpointStorage()
  const stored = resolvedStorage?.getItem(serverEndpointStorageKey)
  if (!stored) return defaultServerEndpoint
  try {
    return normalizeServerEndpoint(stored)
  } catch {
    return defaultServerEndpoint
  }
}

export function saveServerEndpoint(value: string, storage?: EndpointStorage): string {
  const normalized = normalizeServerEndpoint(value)
  const resolvedStorage = storage ?? availableEndpointStorage()
  if (!resolvedStorage) throw new Error('Server settings are unavailable in this environment.')
  resolvedStorage.setItem(serverEndpointStorageKey, normalized)
  return normalized
}

export function resolveServerRequest(input: RequestInfo | URL, endpoint: string): RequestInfo | URL {
  if (typeof input !== 'string') return input
  try {
    return new URL(input).toString()
  } catch {
    return new URL(input, `${normalizeServerEndpoint(endpoint)}/`).toString()
  }
}

/** Uses the browser's same-origin transport on the served web client and the
 * native HTTP plugin from a packaged Tauri app. The dynamic import keeps the
 * web deployment free of runtime Tauri assumptions. */
export async function serverRequest(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  if (!isTauriRuntime()) return fetch(input, init)
  const { fetch: tauriFetch } = await import('@tauri-apps/plugin-http')
  return tauriFetch(resolveServerRequest(input, readServerEndpoint()), init)
}

function availableEndpointStorage(): EndpointStorage | undefined {
  try {
    const storage = (globalThis as { localStorage?: EndpointStorage }).localStorage
    return storage && typeof storage.getItem === 'function' ? storage : undefined
  } catch {
    return undefined
  }
}
