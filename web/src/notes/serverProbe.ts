import {
  assertServerOrigin,
  normalizeServerEndpoint,
  serverCredentialKey,
  type EndpointStorage,
} from './serverEndpoint'

export type ServerProbeResult =
  | { kind: 'connected' }
  | { kind: 'auth-required'; savedCredential: boolean }
  | { kind: 'server-error'; status: number }
  | { kind: 'not-kaiba' }
  | { kind: 'unreachable' }

export type ProbeFetch = (input: string, init: RequestInit) => Promise<Response>

export const serverProbeTimeoutMs = 5000

type ProbeOptions = {
  fetch?: ProbeFetch
  storage?: Pick<EndpointStorage, 'getItem'>
  timeoutMs?: number
}

export async function testServerConnection(
  candidate: string,
  options: ProbeOptions = {},
): Promise<ServerProbeResult> {
  const origin = normalizeServerEndpoint(candidate)
  const fetchProbe = options.fetch ?? (await import('@tauri-apps/plugin-http')).fetch as ProbeFetch
  const timeoutMs = options.timeoutMs ?? serverProbeTimeoutMs

  const healthTarget = `${origin}/healthz`
  assertServerOrigin(healthTarget, origin)
  let healthResponse: Response
  try {
    healthResponse = await fetchWithTimeout(fetchProbe, healthTarget, {
      method: 'GET',
      headers: { Accept: 'application/json' },
    }, timeoutMs)
  } catch {
    return { kind: 'unreachable' }
  }

  if (healthResponse.status !== 200) return { kind: 'not-kaiba' }
  try {
    const health = await healthResponse.json() as { service?: unknown; status?: unknown }
    if (health?.service !== 'kaiba' || health.status !== 'ok') return { kind: 'not-kaiba' }
  } catch {
    return { kind: 'not-kaiba' }
  }

  const graphqlTarget = `${origin}/graphql`
  assertServerOrigin(graphqlTarget, origin)
  let graphqlResponse: Response
  try {
    graphqlResponse = await fetchWithTimeout(fetchProbe, graphqlTarget, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ query: '{ __typename }' }),
    }, timeoutMs)
  } catch {
    return { kind: 'unreachable' }
  }

  if (graphqlResponse.status === 200) return { kind: 'connected' }
  if (graphqlResponse.status === 401) {
    return { kind: 'auth-required', savedCredential: Boolean(readCredentialStorage(options.storage)?.getItem(serverCredentialKey(origin))) }
  }
  return { kind: 'server-error', status: graphqlResponse.status }
}

export function describeServerProbe(result: ServerProbeResult): string {
  switch (result.kind) {
    case 'connected': return 'Connected to a kaiba server.'
    case 'auth-required': return result.savedCredential
      ? 'Kaiba server found. Sign-in required. A saved key for this server will be used after connecting.'
      : 'Kaiba server found. Sign-in required. Paste an API key after connecting.'
    case 'server-error': return `Kaiba server found, but it answered HTTP ${result.status}.`
    case 'not-kaiba': return 'This address answered, but it is not a kaiba server.'
    case 'unreachable': return 'The server could not be reached.'
  }
}

async function fetchWithTimeout(
  fetchProbe: ProbeFetch,
  target: string,
  init: Omit<RequestInit, 'signal'>,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetchProbe(target, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function readCredentialStorage(storage?: Pick<EndpointStorage, 'getItem'>): Pick<EndpointStorage, 'getItem'> | undefined {
  if (storage) return storage
  try {
    return (globalThis as { localStorage?: Pick<EndpointStorage, 'getItem'> }).localStorage
  } catch {
    return undefined
  }
}
