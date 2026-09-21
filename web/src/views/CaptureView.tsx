import { Show, createEffect, createSignal, type JSX } from 'solid-js'
import { errorMessage, isUnauthorized, useApp } from '../state/appStore'
import { LoginView } from './LoginView'
import type { NoteCaptureResult } from '../notes/types'

// Anywhere capture (design-docs/specs/note-capture-and-entity-pages.md, F1).
// The page a phone opens to hold one thought: a textarea, a submit button, and
// nothing else to decide. The server resolves the account's singleton Quick
// Memos notebook and runs the ordinary note-creation path, so auto-tagging
// happens without the page knowing about notebooks at all.
//
// C5 serves this view at the real path `/note/capture` (the SPA bootstrap is
// rewritten to `/` by `KaibaStaticSPAHTTPRouter`), while the reader's own
// routing stays hash-based — so App boots into it by path, never by route.
// An unregistered visitor gets the existing `LoginView`, not a second
// registration surface: `NoteGraphQLClient.initialize()` has already consumed
// any `?code=` from the QR registration link by the time this renders.

/** True for the path C5 rewrites to the SPA bootstrap. A trailing slash is
 * accepted because a phone keyboard adds one and the server rewrite does
 * not. */
export function isCapturePathname(pathname: string): boolean {
  return pathname === '/note/capture' || pathname === '/note/capture/'
}

export function CaptureView(): JSX.Element {
  const app = useApp()
  const [text, setText] = createSignal('')
  const [captured, setCaptured] = createSignal<NoteCaptureResult>()
  const [failure, setFailure] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [credentialRejected, setCredentialRejected] = createSignal(false)

  // The catalog load reports the host's auth mode; a capture rejected with 401
  // (a revoked bearer, already dropped by the client) is the same verdict
  // arriving through this page's own request, and the catalog may not have
  // re-read since. Signing in clears it: `signInWithKey` resets the store to
  // 'unknown' and only reaches 'authenticated' on a credential the server
  // accepted, so this effect fires on that transition and not before.
  createEffect(() => {
    if (app.state.auth === 'authenticated') setCredentialRejected(false)
  })
  const unregistered = () => app.state.auth === 'unauthenticated' || credentialRejected()

  const submit = async (event: Event): Promise<void> => {
    event.preventDefault()
    if (busy() || !text().trim()) return
    setFailure('')
    setCaptured(undefined)
    setBusy(true)
    try {
      setCaptured(await app.client.captureNote(text()))
      setText('')
    } catch (error) {
      if (isUnauthorized(error)) setCredentialRejected(true)
      setFailure(errorMessage(error))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Show when={!unregistered()} fallback={<LoginView />}>
      <main class="login-view">
        <div class="login-card">
          <div class="login-brand">
            <span class="brand-mark">K</span>
            <div class="brand-copy"><strong>Kaiba</strong><span>Capture a thought</span></div>
          </div>

          <p class="login-lead">
            This goes straight into your Quick Memos notebook, where the usual
            auto-tagging picks it up. Nothing else to choose.
          </p>

          <form class="login-form" onSubmit={(event) => void submit(event)}>
            <label class="login-label" for="capture-text">Note</label>
            <textarea
              id="capture-text"
              class="login-input"
              rows={8}
              autocapitalize="sentences"
              placeholder="What is on your mind?"
              value={text()}
              onInput={(event) => setText(event.currentTarget.value)}
            />
            <button type="submit" disabled={busy() || !text().trim()}>
              {busy() ? 'Capturing...' : 'Capture'}
            </button>
          </form>

          <Show when={captured()}>{(note) => (
            <p class="login-lead" role="status" aria-live="polite">
              Captured as <code>{note().noteId}</code> (p.{note().noteNumber}).
            </p>
          )}</Show>

          <Show when={failure()}>
            <p class="login-failure" role="alert">{failure()}</p>
          </Show>
        </div>
      </main>
    </Show>
  )
}
