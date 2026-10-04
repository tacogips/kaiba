import type { SearchEngineSettings, SearchEngineSettingsInput } from './types'

export interface SearchEngineForm {
  kind: string
  url: string
  indexPrefix: string
  authMode: string
  username: string
  secret: string
  clearSecret: boolean
  verifyTLS: boolean
  requestTimeoutSeconds: string
}

export interface SearchEngineFieldError {
  field: string
  message: string
}

export function normalizedTarget(value: string): string | null {
  try {
    const url = new URL(value.trim())
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null
    const path = url.pathname.replace(/\/+$/, '')
    return `${url.protocol.toLowerCase()}//${url.host.toLowerCase()}${path}`
  } catch {
    return null
  }
}

export function validateSearchEngineForm(
  form: SearchEngineForm,
  loaded: SearchEngineSettings,
): SearchEngineFieldError[] {
  const errors: SearchEngineFieldError[] = []
  const add = (field: string, message: string) => errors.push({ field, message })
  let target: string | null = null

  if (form.kind !== 'none') {
    if (!form.url.trim()) add('searchEngine.url', 'URL is required.')
    if (form.url.length > 2048) add('searchEngine.url', 'URL must be 2048 characters or fewer.')
    else {
      target = normalizedTarget(form.url)
      if (!target) add('searchEngine.url', 'Enter an http or https URL without user information.')
      else {
        const url = new URL(form.url.trim())
        const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '')
        if (url.protocol === 'http:' && !['localhost', '127.0.0.1', '::1'].includes(host)) {
          add('searchEngine.url', 'Plain http is allowed only for loopback hosts.')
        }
      }
    }
  }

  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(form.indexPrefix)) {
    add('searchEngine.indexPrefix', 'Use 1–64 lowercase letters, digits, underscores or hyphens.')
  }
  const timeout = Number(form.requestTimeoutSeconds)
  if (!Number.isInteger(timeout) || timeout < 1 || timeout > 120) {
    add('searchEngine.requestTimeoutSeconds', 'Timeout must be an integer from 1 to 120 seconds.')
  }
  if (form.authMode === 'basic' && !form.username.trim()) {
    add('searchEngine.username', 'Username is required for basic authentication.')
  }
  if (form.authMode === 'basic' && form.username.length > 256) {
    add('searchEngine.username', 'Username must be 256 characters or fewer.')
  }
  if (form.secret.length > 4096) add('searchEngine.secret', 'Secret must be 4096 characters or fewer.')
  const hasControlCharacters = (value: string): boolean =>
    [...value].some((character) => {
      const code = character.codePointAt(0) ?? 0
      return code <= 0x1f || code === 0x7f
    })
  const textFields: ReadonlyArray<[string, string]> = [
    ['searchEngine.kind', form.kind],
    ['searchEngine.url', form.url],
    ['searchEngine.indexPrefix', form.indexPrefix],
    ['searchEngine.authMode', form.authMode],
    ['searchEngine.username', form.username],
    ['searchEngine.secret', form.secret],
  ]
  for (const [field, value] of textFields) {
    if (hasControlCharacters(value)) add(field, 'Control characters are not allowed.')
  }
  const adapter = loaded.adapters.find((item) => item.kind === form.kind)
  if (form.kind !== 'none' && adapter && !adapter.authModes.includes(form.authMode)) {
    add('searchEngine.authMode', 'Choose an authentication mode supported by this engine.')
  }
  if (form.clearSecret && form.authMode !== 'none') {
    add('searchEngine.secret', 'A stored secret can only be cleared with authentication disabled.')
  }
  const changedTarget = target !== normalizedTarget(loaded.url ?? '')
  const changedAuthMode = form.authMode !== loaded.authMode
  if (form.authMode !== 'none' && (!loaded.hasSecret || changedTarget || changedAuthMode) && !form.secret) {
    add('searchEngine.secret', 'Enter a secret for this URL and authentication mode.')
  }
  if (!form.verifyTLS && (!form.url.trim() || !form.url.trim().toLowerCase().startsWith('https://'))) {
    add('searchEngine.verifyTLS', 'Certificate verification can be disabled only for https.')
  }
  return errors
}

export function searchEngineSettingsInput(form: SearchEngineForm): SearchEngineSettingsInput {
  return {
    kind: form.kind,
    ...(form.url.trim() ? { url: form.url.trim() } : {}),
    ...(form.indexPrefix.trim() ? { indexPrefix: form.indexPrefix.trim() } : {}),
    authMode: form.authMode,
    ...(form.authMode === 'basic' ? { username: form.username.trim() } : {}),
    ...(form.authMode !== 'none' && form.secret ? { secret: form.secret } : {}),
    ...(form.clearSecret ? { clearSecret: true } : {}),
    verifyTLS: form.verifyTLS,
    requestTimeoutSeconds: Number(form.requestTimeoutSeconds),
  }
}
