import { Show, createSignal, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'

// The unauthenticated surface. It replaces the reader shell outright: with no
// credential the catalog is empty for a reason the reader cannot express, and
// an empty tree reads as "this store has no notebooks" rather than "you are
// not logged in".
//
// The only credential this host understands today is an API key. The
// registration URL printed by `kaiba serve` cannot be linked to from here: it
// carries a single-use code, held in the server's memory, that expires 300
// seconds after startup.

export function LoginView(): JSX.Element {
  const app = useApp()
  const [key, setKey] = createSignal('')
  const [failure, setFailure] = createSignal('')
  const [busy, setBusy] = createSignal(false)

  const submit = async (event: Event): Promise<void> => {
    event.preventDefault()
    if (busy()) return
    setFailure('')
    setBusy(true)
    try {
      await app.signInWithKey(key())
      setKey('')
    } catch (error) {
      setFailure(errorMessage(error))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main class="login-view">
      <div class="login-card">
        <div class="login-brand">
          <span class="brand-mark">K</span>
          <div class="brand-copy"><strong>Kaiba</strong><span>Sign in to this note server</span></div>
        </div>

        <p class="login-lead">
          This server requires a credential. Paste an API key, or open a fresh
          registration link from the terminal running <code>kaiba serve</code>.
        </p>

        <form class="login-form" onSubmit={(event) => void submit(event)}>
          <label class="login-label" for="login-key">API key</label>
          <input
            id="login-key"
            class="login-input"
            type="password"
            autocomplete="off"
            spellcheck={false}
            placeholder="Paste the key"
            value={key()}
            onInput={(event) => setKey(event.currentTarget.value)}
          />
          <button type="submit" disabled={busy() || !key().trim()}>
            {busy() ? 'Checking...' : 'Sign in'}
          </button>
        </form>

        <Show when={failure()}>
          <p class="login-failure" role="alert">{failure()}</p>
        </Show>

        <details class="login-help">
          <summary>How do I get one?</summary>
          <p>Issue a key on the machine running the server:</p>
          <pre><code>kaiba client issue --name "Kaiba Web"</code></pre>
          <p>
            Or restart <code>kaiba serve</code> and open the registration URL it
            prints. That link works once and expires five minutes after startup.
          </p>
        </details>
      </div>
    </main>
  )
}
