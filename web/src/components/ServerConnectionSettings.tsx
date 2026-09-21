import { Show, createSignal, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import {
  isTauriRuntime,
  readServerEndpoint,
  saveServerEndpoint,
  readConnectionMode,
  saveConnectionMode,
  supportsLocalService,
  type ConnectionMode,
} from '../notes/serverEndpoint'

export function ServerConnectionSettings(props: { compact?: boolean }): JSX.Element {
  const [endpoint, setEndpoint] = createSignal(readServerEndpoint())
  const [failure, setFailure] = createSignal('')
  const [mode, setMode] = createSignal<ConnectionMode>(readConnectionMode())
  const [busy, setBusy] = createSignal(false)

  const save = async (event: Event): Promise<void> => {
    event.preventDefault()
    setFailure('')
    setBusy(true)
    try {
      if (mode() === 'remote') saveServerEndpoint(endpoint())
      await saveConnectionMode(mode())
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
          onInput={(event) => setEndpoint(event.currentTarget.value)}
        />
      </div>
      </Show>
      <button type="submit" disabled={busy()} aria-label={mode() === 'local' ? 'Use local storage' : 'Reconnect'} title={mode() === 'local' ? 'Use local storage' : 'Reconnect'}><WorkspaceIcon name="refresh" /></button>
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
