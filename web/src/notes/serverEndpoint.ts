export const serverEndpointStorageKey = 'kaiba-server-endpoint'
export const connectionModeStorageKey = 'kaiba-connection-mode'
export type ConnectionMode = 'local' | 'remote'

export function supportsLocalService(): boolean {
  return !/iPhone|iPad|iPod|Android/.test(globalThis.navigator?.userAgent ?? '')
}

export function readConnectionMode(storage?: EndpointStorage): ConnectionMode {
  const resolved = storage ?? availableEndpointStorage()
  const mode = resolved?.getItem(connectionModeStorageKey)
  if (mode === 'remote' || mode === 'local') return mode
  // Preserve an existing installation's explicitly configured server.
  return resolved?.getItem(serverEndpointStorageKey) || !supportsLocalService() ? 'remote' : 'local'
}

export function usesLocalService(): boolean {
  return isTauriRuntime() && readConnectionMode() === 'local'
}

let localService: Promise<string> | undefined
export async function localServerEndpoint(): Promise<string> {
  localService ??= import('@tauri-apps/api/core')
    .then(({ invoke }) => invoke<string>('start_local_server'))
    .then(normalizeServerEndpoint)
    .catch((error: unknown) => { localService = undefined; throw error })
  return localService
}

export async function saveConnectionMode(mode: ConnectionMode): Promise<void> {
  const storage = availableEndpointStorage()
  if (!storage) throw new Error('Server settings are unavailable in this environment.')
  if (mode === 'local') {
    if (!supportsLocalService()) throw new Error('Local storage is available on macOS.')
    await localServerEndpoint()
  }
  storage.setItem(connectionModeStorageKey, mode)
  // Reload cancels the outgoing UI's requests before the next store is shown.
}
// Keep packaged clients on the conventional local endpoint while allowing a
// development server to move when another workspace already owns port 8787.
export const defaultServerEndpoint = import.meta.env.VITE_KAIBA_SERVER_ENDPOINT?.trim()
  || 'http://127.0.0.1:8787'
/** The bearer issued by one server is meaningless to another and must never
 * travel to a host that did not issue it, so the endpoint module owns the key
 * and `client.ts` imports it. Declaring it here keeps the credential and the
 * origin it belongs to in one place, without a cycle back through the client.
 *
 * This bare key is the pre-scoping storage location. Credentials are now held
 * per origin under `serverCredentialKey`; the bare key survives only so an
 * install created before scoping keeps its session (see `client.ts`). */
export const serverCredentialStorageKey = 'kaiba-note-bearer'

/** Storage key for the credential belonging to one origin. Scoping rather
 * than deleting is what keeps a bearer from reaching a host that did not
 * issue it: a mistyped endpoint reads an absent key instead of destroying the
 * working server's credential, so correcting the typo restores the session. */
export function serverCredentialKey(endpoint: string): string {
  return `${serverCredentialStorageKey}:${endpoint}`
}

/** The credential key for the endpoint currently in effect. */
export function currentServerCredentialKey(storage?: EndpointStorage): string {
  if (!storage && usesLocalService()) return `${serverCredentialStorageKey}:local`
  return serverCredentialKey(readServerEndpoint(storage))
}

export interface EndpointStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
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

/** Repointing the client at a different origin must not carry the previous
 * server's bearer to the new host: nothing downstream revokes it -- the only
 * clear-on-failure path is a 401 from the GraphQL route, and a server started
 * with `kaiba serve --allow-unauthenticated` answers 200 without ever reading
 * the Authorization header. Because credentials are stored per origin, the
 * switch is already safe without destroying anything, and a mistyped endpoint
 * costs nothing: correcting it reads the original origin's key again.
 *
 * The one value that would otherwise follow the user across the switch is a
 * pre-scoping bare credential, so it is filed under the outgoing origin here
 * rather than deleted. */
export function saveServerEndpoint(value: string, storage?: EndpointStorage): string {
  const normalized = normalizeServerEndpoint(value)
  const resolvedStorage = storage ?? availableEndpointStorage()
  if (!resolvedStorage) throw new Error('Server settings are unavailable in this environment.')
  const current = readServerEndpoint(resolvedStorage)
  if (current !== normalized) {
    const unscoped = resolvedStorage.getItem(serverCredentialStorageKey)
    if (unscoped) {
      resolvedStorage.setItem(serverCredentialKey(current), unscoped)
      resolvedStorage.removeItem(serverCredentialStorageKey)
    }
  }
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
  const local = usesLocalService()
  const endpoint = local ? await localServerEndpoint() : readServerEndpoint()
  const target = resolveServerRequest(input, endpoint)
  assertServerOrigin(target, endpoint)
  if (local) {
    const headers = new Headers(init?.headers)
    headers.delete('Authorization')
    try {
      return await tauriFetch(target, { ...init, headers })
    } catch (error) {
      if (!init?.signal?.aborted) localService = undefined
      throw error
    }
  }
  return tauriFetch(target, init)
}

/** The caller has already attached the configured server's bearer by the time a
 * request reaches here, so the target must belong to that server. Path
 * resolution alone does not guarantee it: a protocol-relative string such as
 * `//other.test/x` fails `new URL(input)` and is then resolved against the
 * endpoint base into a cross-origin URL, and a `URL` or `Request` input is
 * passed through untouched. No caller does either today; this makes the origin
 * contract mechanical instead of a property of every future caller's URL
 * hygiene. */
export function assertServerOrigin(target: RequestInfo | URL, endpoint: string): void {
  const resolved = typeof target === 'string' ? target
    : target instanceof URL ? target.href
      : target.url
  let origin: string
  try {
    origin = new URL(resolved).origin
  } catch {
    throw new Error('The request target could not be resolved against the Kaiba server URL.')
  }
  if (origin !== new URL(normalizeServerEndpoint(endpoint)).origin) {
    throw new Error('Refusing to send a Kaiba server request to a different origin.')
  }
}

function availableEndpointStorage(): EndpointStorage | undefined {
  try {
    const storage = (globalThis as { localStorage?: EndpointStorage }).localStorage
    if (!storage) return undefined
    const usable = typeof storage.getItem === 'function'
      && typeof storage.setItem === 'function'
      && typeof storage.removeItem === 'function'
    return usable ? storage : undefined
  } catch {
    return undefined
  }
}
