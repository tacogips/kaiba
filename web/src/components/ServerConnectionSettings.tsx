import { For, Show, createSignal, type JSX } from 'solid-js'
import './form-controls.css'
import { WorkspaceIcon } from './WorkspaceIcon'
import {
  isTauriRuntime,
  readServerEndpoint,
  saveServerEndpoint,
  readConnectionMode,
  saveConnectionMode,
  supportsLocalService,
  activeConnectionLabel,
  isUnencryptedRemoteEndpoint,
  readRecentServerEndpoints,
  recordRecentServerEndpoint,
  type ConnectionMode,
} from '../notes/serverEndpoint'
import { describeServerProbe, testServerConnection } from '../notes/serverProbe'

export function ServerConnectionSettings(props: { compact?: boolean }): JSX.Element {
  const [endpoint, setEndpoint] = createSignal(readServerEndpoint())
  const [failure, setFailure] = createSignal('')
  const [mode, setMode] = createSignal<ConnectionMode>(readConnectionMode())
  const [busy, setBusy] = createSignal(false)
  const [probing, setProbing] = createSignal(false)
  const [probeText, setProbeText] = createSignal('')
  const [recentEndpoint, setRecentEndpoint] = createSignal('')
  const activeLabel = activeConnectionLabel()
  const recentEndpoints = readRecentServerEndpoints()
  let probeGeneration = 0

  const testConnection = async (): Promise<void> => {
    const generation = ++probeGeneration
    setProbeText('')
    setProbing(true)
    try {
      const result = await testServerConnection(endpoint())
      if (generation === probeGeneration) setProbeText(describeServerProbe(result))
    } catch (error) {
      if (generation === probeGeneration) setProbeText(error instanceof Error ? error.message : String(error))
    } finally {
      if (generation === probeGeneration) setProbing(false)
    }
  }

  const save = async (event: Event): Promise<void> => {
    event.preventDefault()
    setFailure('')
    setBusy(true)
    try {
      const normalized = mode() === 'remote' ? saveServerEndpoint(endpoint()) : undefined
      await saveConnectionMode(mode())
      if (normalized) {
        try { recordRecentServerEndpoint(normalized) } catch { /* Recent history must not block a successful save. */ }
      }
      window.location.reload()
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(false)
    }
  }

  const form = (): JSX.Element => (
    <form classList={{ 'server-connection': true, compact: Boolean(props.compact) }} onSubmit={save}>
      <label>
        Connection
        <select aria-label="Connection mode" value={mode()} disabled={busy()}
          onChange={(event) => setMode(event.currentTarget.value as ConnectionMode)}>
          <option value="local" disabled={!supportsLocalService()}>Local — this Mac</option>
          <option value="remote">Remote server</option>
        </select>
      </label>
      <p class="server-connection-active">Active: {activeLabel}</p>
      <Show when={mode() === 'remote'} fallback={
        <p>Stored on this Mac.</p>
      }>
      <label for={props.compact ? 'login-server-endpoint' : 'server-endpoint'}>Kaiba server URL</label>
      <div class="server-connection-row">
        <input
          id={props.compact ? 'login-server-endpoint' : 'server-endpoint'}
          type="url"
          inputmode="url"
          autocomplete="url"
          spellcheck={false}
          placeholder="https://notes.example.com"
          value={endpoint()}
          onInput={(event) => {
            setEndpoint(event.currentTarget.value)
            probeGeneration += 1
            setProbeText('')
            setProbing(false)
          }}
        />
        <button type="button" class="secondary" aria-label="Test connection" disabled={busy() || probing()}
          onClick={() => void testConnection()}>{probing() ? 'Testing…' : 'Test connection'}</button>
      </div>
      <Show when={mode() === 'remote' && recentEndpoints.length > 0}>
        <label>Recent servers
          <select aria-label="Recent servers" value={recentEndpoint()} disabled={busy()}
            onChange={(event) => {
              const value = event.currentTarget.value
              setRecentEndpoint('')
              event.currentTarget.value = ''
              if (value) {
                setEndpoint(value)
                probeGeneration += 1
                setProbeText('')
                setProbing(false)
              }
            }}>
            <option value="">Choose a recent server</option>
            <For each={recentEndpoints}>{(recent) => <option value={recent}>{recent}</option>}</For>
          </select>
        </label>
      </Show>
      <Show when={mode() === 'remote' && isUnencryptedRemoteEndpoint(endpoint())}>
        <p class="server-connection-warning">This server uses plain HTTP; the API key travels unencrypted.</p>
      </Show>
      <Show when={probeText()}><p class="server-connection-probe" role="status">{probeText()}</p></Show>
      </Show>
      <button type="submit" class="form-icon-button" aria-busy={busy()} disabled={busy()} aria-label={mode() === 'local' ? 'Use local storage' : 'Reconnect'} title={mode() === 'local' ? 'Use local storage' : 'Reconnect'}><WorkspaceIcon name="refresh" /></button>
      <Show when={failure()}><p class="login-failure" role="alert">{failure()}</p></Show>
    </form>
  )

  // The section chrome lives inside the runtime gate, not at the call site: a
  // caller that wrapped this component in its own <section> would render an
  // empty card in the browser, where the form is deliberately absent.
  return (
    <Show when={isTauriRuntime()}>
      <Show when={!props.compact} fallback={form()}>
        <section class="config-section">
          <h2>Server connection</h2>
          {form()}
        </section>
      </Show>
    </Show>
  )
}
