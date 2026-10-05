import { For, Show, createMemo, createResource, createSignal, type JSX } from 'solid-js'
import { useApp, type AppStore } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { SearchEngineSettings as Settings } from '../notes/types'
import {
  defaultEngineURL,
  searchEngineSettingsInput,
  normalizedTarget,
  validateSearchEngineForm,
  type SearchEngineForm,
} from '../notes/searchEngineSettings'

export interface SearchEngineSettingsProps {
  client?: Pick<NoteGraphQLClient, 'searchEngineSettings' | 'updateSearchEngineSettings' | 'testSearchEngineConnection'>
  app?: Pick<AppStore, 'client' | 'reloadSearchEngineCapability'>
}

function formFrom(settings: Settings): SearchEngineForm {
  return {
    kind: settings.kind,
    url: settings.url ?? '',
    indexPrefix: settings.indexPrefix ?? 'kaiba',
    authMode: settings.authMode,
    username: settings.username ?? '',
    secret: '',
    clearSecret: false,
    verifyTLS: settings.verifyTLS,
    requestTimeoutSeconds: String(settings.requestTimeoutSeconds),
  }
}

export function SearchEngineSettings(props: SearchEngineSettingsProps = {}): JSX.Element {
  const app = props.app ?? useApp()
  const client = props.client ?? app.client
  const [settings, { mutate }] = createResource(() => client.searchEngineSettings?.() ?? Promise.resolve(null))
  const [form, setForm] = createSignal<SearchEngineForm | undefined>()
  const [busy, setBusy] = createSignal(false)
  const [failure, setFailure] = createSignal('')
  const [testResult, setTestResult] = createSignal<{ status: string; detail: string }>()

  const seed = (value: Settings | null | undefined): void => {
    if (value && !form()) setForm(formFrom(value))
  }
  const errors = createMemo(() => {
    const current = form()
    const loaded = settings()
    return current && loaded ? validateSearchEngineForm(current, loaded) : []
  })
  const secretRequired = (): boolean => {
    const current = form()
    const loaded = settings()
    return Boolean(current && loaded && current.authMode !== 'none'
      && (!loaded.hasSecret
        || normalizedTarget(current.url) !== normalizedTarget(loaded.url ?? '')
        || current.authMode !== loaded.authMode))
  }
  const storedSecretMatches = (): boolean => {
    const current = form()
    const loaded = settings()
    return Boolean(current && loaded?.hasSecret
      && normalizedTarget(current.url) === normalizedTarget(loaded.url ?? '')
      && current.authMode === loaded.authMode)
  }
  const update = (partial: Partial<SearchEngineForm>): void => {
    const current = form()
    if (current) {
      setForm({
        ...current,
        ...partial,
        ...(partial.authMode === 'none' ? { secret: '', clearSecret: false } : {}),
      })
    }
    setFailure('')
    setTestResult(undefined)
  }
  const runTest = async (): Promise<void> => {
    const current = form()
    if (!current || errors().length) return
    setBusy(true)
    setFailure('')
    setTestResult(undefined)
    try {
      const result = await client.testSearchEngineConnection(searchEngineSettingsInput(current))
      setTestResult({ status: result.status, detail: result.detail })
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }
  const save = async (event: Event): Promise<void> => {
    event.preventDefault()
    const current = form()
    if (!current || errors().length) return
    setBusy(true)
    setFailure('')
    try {
      const saved = await client.updateSearchEngineSettings(searchEngineSettingsInput(current))
      mutate(saved)
      setForm(formFrom(saved))
      await app.reloadSearchEngineCapability()
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Show when={settings()}>
      {(value) => {
        seed(value())
        return (
          <section class="config-section" data-testid="search-engine-settings">
            <h2>Search engine</h2>
            <Show when={value().managedBy === 'config'}>
              <p class="pane-note">Managed by the server configuration file</p>
              <dl>
                <dt>Engine</dt><dd>{value().kind}</dd>
                <dt>URL</dt><dd>{value().url ?? '—'}</dd>
                <dt>Index prefix</dt><dd>{value().indexPrefix ?? '—'}</dd>
                <dt>Authentication</dt><dd>{value().authMode}</dd>
                <dt>Status</dt><dd>{value().active ? 'Active' : 'Inactive'}</dd>
              </dl>
            </Show>
            <Show when={value().managedBy !== 'config' && form()}>
              <form onSubmit={save}>
                <label>
                  <span>Engine</span>
                  <select value={form()?.kind} onChange={(event) => {
                    const kind = event.currentTarget.value
                    const adapter = value().adapters.find((item) => item.kind === kind)
                    update({ kind, authMode: adapter?.authModes[0] ?? 'none', url: defaultEngineURL(kind, form()?.url ?? '', value().adapters) })
                  }}>
                    <option value="none">None</option>
                    <For each={value().adapters}>{(adapter) => <option value={adapter.kind}>{adapter.displayName}</option>}</For>
                  </select>
                </label>
                <Show when={form()?.kind !== 'none'}>
                  <label><span>URL</span><input type="url" value={form()?.url} onInput={(event) => update({ url: event.currentTarget.value })} /></label>
                  <label><span>Index prefix</span><input value={form()?.indexPrefix} onInput={(event) => update({ indexPrefix: event.currentTarget.value })} /></label>
                  <label>
                    <span>Authentication</span>
                    <select value={form()?.authMode} onChange={(event) => update({ authMode: event.currentTarget.value })}>
                      <For each={value().adapters.find((item) => item.kind === form()?.kind)?.authModes ?? ['none']}>
                        {(mode) => <option value={mode}>{mode}</option>}
                      </For>
                    </select>
                  </label>
                  <Show when={form()?.authMode === 'basic'}>
                    <label><span>Username</span><input value={form()?.username} onInput={(event) => update({ username: event.currentTarget.value })} /></label>
                  </Show>
                  <label>
                    <span>Secret</span>
                    <input
                      type="password"
                      autocomplete="new-password"
                      value={form()?.secret}
                      placeholder={storedSecretMatches() ? 'Stored' : undefined}
                      required={secretRequired()}
                      onInput={(event) => update({ secret: event.currentTarget.value })}
                    />
                  </label>
                  <label><input type="checkbox" checked={form()?.clearSecret} onChange={(event) => update({ clearSecret: event.currentTarget.checked })} /> Clear stored secret</label>
                  <label>
                    <input type="checkbox" checked={form()?.verifyTLS} disabled={!form()?.url.toLowerCase().startsWith('https://')} onChange={(event) => update({ verifyTLS: event.currentTarget.checked })} />
                    Verify TLS certificates
                  </label>
                  <Show when={!form()?.verifyTLS}><p class="pane-note">Certificate verification is off; use only on a trusted network</p></Show>
                  <label><span>Request timeout (seconds)</span><input type="number" min="1" max="120" step="1" value={form()?.requestTimeoutSeconds} onInput={(event) => update({ requestTimeoutSeconds: event.currentTarget.value })} /></label>
                </Show>
                <For each={errors()}>{(error) => <p class="login-failure" role="alert">{error.message}</p>}</For>
                <div class="user-agent-actions">
                  <button type="button" class="secondary" disabled={busy() || errors().length > 0} onClick={() => void runTest()}>Test connection</button>
                  <button type="submit" disabled={busy() || errors().length > 0}>Save</button>
                </div>
              </form>
            </Show>
            <Show when={testResult()}>{(result) => <p role="status">{result().status}: {result().detail}</p>}</Show>
            <Show when={failure()}><p role="alert" class="login-failure">{failure()}</p></Show>
          </section>
        )
      }}
    </Show>
  )
}
