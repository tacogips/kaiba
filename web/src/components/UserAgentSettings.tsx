import { For, Show, createResource, createSignal, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import type { UserAgentCredentialState } from '../notes/types'

/** The "Personal AI agent" card on the Config screen
 * (design-docs/specs/user-agent-tools.md, UA7). The API key is write-only:
 * the server returns a four-character hint and never the key, so the field
 * starts empty even when a credential is stored. */

export interface UserAgentSettingsProps {
  /** Injected in tests; defaults to the app store's client. */
  client?: Pick<
    NoteGraphQLClient,
    'userAgentCredential' | 'setUserAgentCredential' | 'setUserAgentCredentialEnabled' | 'clearUserAgentCredential'
  >
}

const providerLabels: Record<string, string> = {
  codex: 'Codex (subscription on server)',
  server: 'Server default',
  anthropic: 'Anthropic',
  openai: 'OpenAI',
  openrouter: 'OpenRouter',
  'openai-compatible': 'OpenAI-compatible endpoint',
}

export function providerLabel(provider: string): string {
  return providerLabels[provider] ?? provider
}

export function UserAgentSettings(props: UserAgentSettingsProps): JSX.Element {
  const client = props.client ?? useApp().client
  const [state, { mutate }] = createResource<UserAgentCredentialState>(() => client.userAgentCredential())
  const [provider, setProvider] = createSignal('anthropic')
  const [apiKey, setApiKey] = createSignal('')
  const [model, setModel] = createSignal('')
  const [baseURL, setBaseURL] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [failure, setFailure] = createSignal('')
  const [notice, setNotice] = createSignal('')
  const [seeded, setSeeded] = createSignal(false)

  const seedFromServer = (value: UserAgentCredentialState | undefined): void => {
    if (!value || seeded()) return
    setSeeded(true)
    if (value.credential) {
      setProvider(value.credential.provider)
      setModel(value.credential.defaultModel)
      setBaseURL(value.credential.baseURL ?? '')
    }
  }

  const run = async (work: () => Promise<UserAgentCredentialState>, done: string): Promise<void> => {
    setBusy(true)
    setFailure('')
    setNotice('')
    try {
      mutate(await work())
      setNotice(done)
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  const save = (event: Event): void => {
    event.preventDefault()
    const key = apiKey().trim()
    if (provider() !== 'codex' && !key) {
      setFailure('Enter the API key to save.')
      return
    }
    void run(async () => {
      const result = await client.setUserAgentCredential({
        provider: provider(),
        apiKey: provider() === 'codex' ? '' : key,
        defaultModel: model().trim(),
        baseURL: provider() === 'codex' ? null : baseURL().trim() ? baseURL().trim() : null,
        enabled: true,
      })
      setApiKey('')
      return result
    }, 'AI settings saved.')
  }

  const toggle = (enabled: boolean): void => {
    void run(() => client.setUserAgentCredentialEnabled(enabled), enabled ? 'Personal agent enabled.' : 'Personal agent disabled.')
  }

  const clear = (): void => {
    void run(async () => {
      const result = await client.clearUserAgentCredential()
      setApiKey('')
      return result
    }, 'Credential removed.')
  }

  return (
    <section class="config-section" data-testid="user-agent-settings">
      <h2>Personal AI agent</h2>
      <Show when={state()} fallback={<p class="pane-note">Loading...</p>}>{(value) => {
        seedFromServer(value())
        return (
          <Show
            when={value().featureEnabled}
            fallback={<p class="pane-note">Personal agents are turned off on this server.</p>}
          >
            <p class="pane-note">
              Choose a provider and default model. Saved API keys remain hidden.
            </p>
            <Show when={!value().providers.includes('codex')}>
              <p class="pane-note">Codex subscription requires the server operator to enable ai.userAgent.allowCodexSubscription and sign in to Codex on the server.</p>
            </Show>
            <Show when={value().credential}>{(credential) =>
              <p class="user-agent-status" data-testid="user-agent-status">
                Stored: {providerLabel(credential().provider)} / {credential().defaultModel} /
                {credential().provider === 'codex' ? 'server subscription' : `key ending in ${credential().keyHint}`} /{' '}
                {credential().enabled ? 'enabled' : 'disabled'}
              </p>}
            </Show>
            <form class="user-agent-form" onSubmit={save}>
              <label>
                <span>Provider</span>
                <select
                  id="user-agent-provider"
                  value={provider()}
                  onChange={(event) => setProvider(event.currentTarget.value)}
                >
                  <For each={value().providers}>{(item) =>
                    <option value={item}>{providerLabel(item)}</option>}
                  </For>
                </select>
              </label>
              <Show when={provider() !== 'codex'} fallback={<p class="pane-note">Uses the server’s Codex ChatGPT login through agent-gateway. No API key is needed.</p>}>
              <label>
                <span>API key</span>
                <input
                  id="user-agent-api-key"
                  type="password"
                  autocomplete="off"
                  spellcheck={false}
                  placeholder={value().credential ? `stored (ends in ${value().credential?.keyHint}); enter to replace` : 'sk-...'}
                  value={apiKey()}
                  onInput={(event) => setApiKey(event.currentTarget.value)}
                />
              </label>
              </Show>
              <label>
                <span>Model</span>
                <input
                  id="user-agent-model"
                  type="text"
                  spellcheck={false}
                  placeholder="e.g. claude-opus-5 or openai/gpt-5"
                  value={model()}
                  onInput={(event) => setModel(event.currentTarget.value)}
                />
              </label>
              <Show when={provider() !== 'codex' && (value().customBaseURLAllowed || provider() === 'openai-compatible')}>
                <label>
                  <span>Base URL{value().customBaseURLAllowed ? ' (optional)' : ' (not permitted on this server)'}</span>
                  <input
                    id="user-agent-base-url"
                    type="url"
                    spellcheck={false}
                    placeholder="https://example.com/v1"
                    value={baseURL()}
                    onInput={(event) => setBaseURL(event.currentTarget.value)}
                  />
                </label>
              </Show>
              <div class="user-agent-actions">
                <button type="submit" disabled={busy()}>{provider() === 'codex' ? 'Save subscription settings' : 'Save key'}</button>
                <Show when={value().credential}>{(credential) => <>
                  <button
                    type="button"
                    class="secondary"
                    disabled={busy()}
                    onClick={() => toggle(!credential().enabled)}
                  >{credential().enabled ? 'Disable' : 'Enable'}</button>
                  <button type="button" class="secondary" disabled={busy()} onClick={clear}>Remove key</button>
                </>}</Show>
              </div>
            </form>
            <Show when={notice()}><p class="pane-note" role="status">{notice()}</p></Show>
            <Show when={failure()}><p class="login-failure" role="alert">{failure()}</p></Show>
          </Show>
        )
      }}</Show>
    </section>
  )
}
