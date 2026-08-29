import { Show, createSignal, type JSX } from 'solid-js'
import {
  isTauriRuntime,
  readServerEndpoint,
  saveServerEndpoint,
} from '../notes/serverEndpoint'

export function ServerConnectionSettings(props: { compact?: boolean }): JSX.Element {
  const [endpoint, setEndpoint] = createSignal(readServerEndpoint())
  const [failure, setFailure] = createSignal('')

  const save = (event: Event): void => {
    event.preventDefault()
    setFailure('')
    try {
      saveServerEndpoint(endpoint())
      window.location.reload()
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error))
    }
  }

  const form = (): JSX.Element => (
    <form classList={{ 'server-connection': true, compact: Boolean(props.compact) }} onSubmit={save}>
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
        <button type="submit">Reconnect</button>
      </div>
      <p>
        On iPhone, use an HTTPS or LAN address reachable from the phone;
        127.0.0.1 refers to the phone itself.
      </p>
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

