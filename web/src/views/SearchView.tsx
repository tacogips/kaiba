import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { MarkdownBody } from '../components/Markdown'
import { errorMessage, useApp } from '../state/appStore'
import { noteDisplayTitle } from '../notes/noteText'
import type { NoteSearchResult } from '../notes/types'
import type { Route } from '../router'

// The search results screen. Grep runs the store's full-text search and lists
// matching notes; agentic search hands the question to the configured agent
// (which greps notes and memos through the kaiba CLI when its runtime can run
// commands) and renders its markdown answer.

type SearchRoute = Extract<Route, { kind: 'search' }>

export function SearchView(): JSX.Element {
  const app = useApp()
  const [results, setResults] = createSignal<NoteSearchResult[]>([])
  const [answer, setAnswer] = createSignal('')
  const [status, setStatus] = createSignal('')
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0

  const route = (): SearchRoute | undefined =>
    app.state.route.kind === 'search' ? app.state.route : undefined

  createEffect(() => {
    const current = route()
    if (!current || current.query.trim().length === 0) {
      generation += 1
      setResults([])
      setAnswer('')
      setStatus('')
      return
    }
    void run(current)
  })

  const run = async (current: SearchRoute) => {
    const requested = ++generation
    setLoading(true)
    setError('')
    setResults([])
    setAnswer('')
    setStatus('')
    const notebookId = current.scope === 'notebook' ? current.notebookId : undefined
    try {
      if (current.method === 'grep') {
        const found = await app.client.searchNotes({
          query: current.query,
          ...(notebookId ? { notebookId } : {}),
          limit: 50,
        })
        if (requested !== generation) return
        setResults(found)
      } else {
        const outcome = await app.client.agenticSearch({
          query: current.query,
          ...(notebookId ? { notebookId } : {}),
        })
        if (requested !== generation) return
        setStatus(outcome.status)
        setAnswer(outcome.answerMarkdown ?? '')
      }
    } catch (searchError) {
      if (requested !== generation) return
      setError(errorMessage(searchError))
    } finally {
      if (requested === generation) setLoading(false)
    }
  }

  return (
    <div class="search-view">
      <header class="search-head">
        <span class="eyebrow">
          {route()?.method === 'grep' ? 'Grep search' : 'Agentic search'}
          {route()?.scope === 'notebook' ? ' · this notebook' : ' · all notebooks'}
        </span>
        <h1>{route()?.query}</h1>
      </header>
      <Show when={loading()}>
        <div class="loading-state">
          <span class="loader" />
          {route()?.method === 'agentic'
            ? 'The agent is searching… this can take a while.'
            : 'Searching…'}
        </div>
      </Show>
      <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
      <Show when={status() === 'agent-unavailable'}>
        <p class="chat-banner" role="status">
          Agent runtime not configured — agentic search needs one. Try grep search instead.
        </p>
      </Show>

      <Show when={route()?.method === 'grep' && !loading()}>
        <Show when={results().length === 0 && !error()}>
          <p class="pane-empty">No matches.</p>
        </Show>
        <ul class="search-results">
          <For each={results()}>{(result) =>
            <li>
              <button
                type="button"
                class="search-result"
                onClick={() => app.openNote(result.note.noteId, result.note.notebookId)}
              >
                <strong>{noteDisplayTitle(result.note)}</strong>
                <span class="link-meta">
                  p.{result.note.noteNumber}
                  {result.isLinkedNeighbor ? ' · linked' : ''}
                  {result.termCoverage < 1 ? ` · partial ${Math.round(result.termCoverage * 100)}%` : ''}
                </span>
                <span class="search-snippet">{result.snippet}</span>
              </button>
            </li>}
          </For>
        </ul>
      </Show>

      <Show when={route()?.method === 'agentic' && !loading() && answer()}>
        <article class="search-answer">
          <MarkdownBody markdown={answer()} anchorIds={false} />
        </article>
      </Show>
    </div>
  )
}
