import { For, Show, createEffect, createSignal, type JSX } from 'solid-js'
import { MarkdownBody } from '../components/Markdown'
import { errorMessage, useApp } from '../state/appStore'
import { NoteTransportError } from '../notes/client'
import { noteDisplayTitle } from '../notes/noteText'
import type { EngineSearchFacets, NoteSearchResult } from '../notes/types'
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
  const [notice, setNotice] = createSignal('')
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  const [facets, setFacets] = createSignal<EngineSearchFacets | null>(null)
  const [tagFilter, setTagFilter] = createSignal<string[]>([])
  const [tagClassFilter, setTagClassFilter] = createSignal<string[]>([])
  const [engineDisabledByResult, setEngineDisabledByResult] = createSignal(false)
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
      setNotice('')
      setFacets(null)
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
    setNotice('')
    setFacets(null)
    const notebookId = current.scope === 'notebook' ? current.notebookId : undefined
    try {
      if (current.method === 'grep') {
        let found: NoteSearchResult[]
        if (app.state.searchEngineEnabled) {
          try {
            const page = await app.client.engineSearchNotes({
              query: current.query,
              ...(notebookId ? { notebookId } : {}),
              ...(tagFilter().length ? { tagFilter: tagFilter() } : {}),
              ...(tagClassFilter().length ? { tagClassFilter: tagClassFilter() } : {}),
              facets: true,
              limit: 50,
            })
            if (requested !== generation) return
            setFacets(page.facets)
            found = page.hits.map((hit) => ({
              note: hit.note,
              snippet: hit.snippet,
              rank: hit.score,
              matchedTags: [],
              isLinkedNeighbor: false,
              termCoverage: 1,
            }))
          } catch (searchError) {
            if (!(searchError instanceof NoteTransportError)
              || !['search-engine-unavailable', 'feature-disabled'].includes(searchError.resultStatus ?? '')) {
              throw searchError
            }
            if (searchError.resultStatus === 'feature-disabled') {
              setEngineDisabledByResult(true)
              app.setSearchEngineEnabled(false)
            }
            if (tagClassFilter().length > 0) setTagClassFilter([])
            setFacets(null)
            found = await app.client.searchNotes({
              query: current.query,
              ...(notebookId ? { notebookId } : {}),
              ...(tagFilter().length ? { tagFilter: tagFilter() } : {}),
              limit: 50,
            })
            if (requested !== generation) return
            setNotice('Search engine unavailable; showing built-in results')
          }
        } else {
          if (engineDisabledByResult()) setNotice('Search engine unavailable; showing built-in results')
          found = await app.client.searchNotes({
            query: current.query,
            ...(notebookId ? { notebookId } : {}),
            ...(tagFilter().length ? { tagFilter: tagFilter() } : {}),
            limit: 50,
          })
        }
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
    <main class="search-view" id="main-content" tabindex="-1">
      <header class="search-head">
        <span class="eyebrow">
          {route()?.method === 'grep' ? 'Find text' : 'Ask your knowledge'}
          {route()?.scope === 'notebook' ? ' · this notebook' : ' · all notebooks'}
        </span>
        <h1>{route()?.query}</h1>
      </header>
      <Show when={loading()}>
        <div class="loading-state">
          <span class="loader" />
          {route()?.method === 'agentic'
            ? 'AI is exploring your notes…'
            : 'Searching…'}
        </div>
      </Show>
      <Show when={error()}><div role="alert"><p class="note-inline-error">{error()}</p>
        <button type="button" class="secondary" onClick={() => { const current = route(); if (current) void run(current) }}>Try again</button>
      </div></Show>
      <Show when={status() === 'agent-unavailable'}>
        <p class="chat-banner" role="status">
          AI search is not available. You can still find text in your notes.
          <button type="button" class="secondary" onClick={() => {
            const current = route()
            if (current) app.openSearch(current.query, current.scope, 'grep')
          }}>Find text instead</button>
        </p>
      </Show>

      <Show when={notice()}>
        <p class="chat-banner" role="status">{notice()}</p>
      </Show>

      <Show when={route()?.method === 'grep' && facets()}>{(availableFacets) =>
        <div class="detail-chips" aria-label="Search refinements">
          <For each={availableFacets().tagClasses}>{(facet) =>
            <button type="button" class="folder-chip" onClick={() => {
              const next = tagClassFilter().includes(facet.value)
                ? tagClassFilter() : [...tagClassFilter(), facet.value]
              setTagClassFilter(next)
            }}>{facet.value} {facet.count}</button>}
          </For>
          <For each={availableFacets().tags}>{(facet) =>
            <button type="button" class="folder-chip" onClick={() => {
              const next = tagFilter().includes(facet.name) ? tagFilter() : [...tagFilter(), facet.name]
              setTagFilter(next)
            }}>{facet.name} {facet.count}</button>}
          </For>
        </div>}
      </Show>
      <Show when={tagFilter().length > 0 || tagClassFilter().length > 0}>
        <div class="detail-chips" aria-label="Active search filters">
          <For each={tagClassFilter()}>{(value) => <span class="folder-chip">{value}<button type="button" aria-label={`Remove filter ${value}`} onClick={() => {
            setTagClassFilter(tagClassFilter().filter((item) => item !== value))
          }}>x</button></span>}</For>
          <For each={tagFilter()}>{(value) => <span class="folder-chip">{value}<button type="button" aria-label={`Remove filter ${value}`} onClick={() => {
            setTagFilter(tagFilter().filter((item) => item !== value))
          }}>x</button></span>}</For>
        </div>
      </Show>

      <Show when={route()?.method === 'grep' && !loading()}>
        <Show when={results().length === 0 && !error()}>
          <p class="pane-empty">No matching notes. Try a shorter phrase or search all notebooks.</p>
        </Show>
        <ul class="search-results">
          <For each={results()}>{(result) =>
            <li>
              <button
                type="button"
                class="search-result"
                onClick={() => app.openNoteWithReturn(result.note.noteId, result.note.notebookId)}
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
    </main>
  )
}
