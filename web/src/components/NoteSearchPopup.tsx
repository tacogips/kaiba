import { For, Show, createSignal, onMount } from 'solid-js'
import type { NoteGraphQLClient } from '../notes/client'
import type { NoteSearchResult, NoteTag } from '../notes/types'
import { qualifiedTagLabel } from '../notes/tree'
import { noteDisplayTitle, searchPageSize } from '../notes/noteText'
import { errorMessage } from '../state/appStore'
import type { NoteId, NotebookId } from '../notes/ids'

/** Full-text note search presented as a popup, mirroring
 * RielaNoteSearchPopupSheet: picking a result opens that note and dismisses. */
export function NoteSearchPopup(props: {
  client: NoteGraphQLClient
  tags: NoteTag[]
  initialQuery?: string
  onOpenNote: (noteId: NoteId, notebookId: NotebookId) => void
  onClose: () => void
}) {
  const [query, setQuery] = createSignal(props.initialQuery ?? '')
  const [results, setResults] = createSignal<NoteSearchResult[]>([])
  const [offset, setOffset] = createSignal(0)
  const [hasMore, setHasMore] = createSignal(false)
  const [searching, setSearching] = createSignal(false)
  const [searched, setSearched] = createSignal(false)
  const [error, setError] = createSignal('')
  let input: HTMLInputElement | undefined
  // Only the newest query may publish results; a slower earlier search that
  // resolves late is dropped instead of overwriting the visible list.
  let generation = 0

  onMount(() => {
    input?.focus()
    if (query().trim()) void search(false)
  })

  const search = async (append: boolean) => {
    const normalized = query().trim()
    if (!normalized) {
      generation += 1
      setResults([])
      setOffset(0)
      setHasMore(false)
      setSearched(false)
      return
    }
    const current = append ? generation : (generation += 1)
    const nextOffset = append ? offset() : 0
    setSearching(true)
    setError('')
    try {
      const page = await props.client.searchNotes({
        query: normalized,
        limit: searchPageSize,
        offset: nextOffset,
      })
      if (current !== generation) return
      setResults((existing) => append ? [...existing, ...page] : page)
      setOffset(nextOffset + page.length)
      setHasMore(page.length === searchPageSize)
      setSearched(true)
    } catch (searchError) {
      if (current !== generation) return
      setError(errorMessage(searchError))
    } finally {
      if (current === generation) setSearching(false)
    }
  }

  return <div class="note-modal-backdrop" role="presentation" onClick={(event) => {
    if (event.target === event.currentTarget) props.onClose()
  }}>
    <section class="note-modal note-search" role="dialog" aria-modal="true" aria-label="Search notes">
      <header>
        <div><span class="eyebrow">SEARCH</span><h2>Search notes</h2></div>
        <button class="secondary" aria-label="Close search" onClick={props.onClose}>×</button>
      </header>
      <div class="note-search-field">
        <label>
          <span class="sr-only">Search full note text</span>
          <input
            ref={input}
            type="search"
            aria-label="Search full note text"
            placeholder="Search full note text"
            value={query()}
            onInput={(event) => setQuery(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') void search(false)
              if (event.key === 'Escape') props.onClose()
            }}
          />
        </label>
        <button disabled={searching() || !query().trim()} onClick={() => void search(false)}>Search</button>
      </div>
      <Show when={error()}><p class="note-inline-error" role="alert">{error()}</p></Show>
      <Show when={searching() && results().length === 0}>
        <div class="loading-state"><span class="loader" />Searching notes…</div>
      </Show>
      <Show when={!searching() && searched() && results().length === 0 && !error()}>
        <p class="note-search-empty">No notes match that query.</p>
      </Show>
      <Show when={!searched() && results().length === 0 && !searching()}>
        <p class="note-search-empty">Type a query to find matching notes.</p>
      </Show>
      <ul class="note-search-results" aria-label="Search results">
        <For each={results()}>{(result) =>
          <li>
            <button onClick={() => {
              props.onOpenNote(result.note.noteId, result.note.notebookId)
              props.onClose()
            }}>
              <strong>{noteDisplayTitle(result.note)}</strong>
              <Show when={result.snippet.trim()}><span class="note-search-snippet">{result.snippet}</span></Show>
              <span class="note-search-meta">
                #{result.note.noteNumber}
                <Show when={result.isLinkedNeighbor}><em> · linked neighbor</em></Show>
                <For each={result.matchedTags}>{(tag) => <em> · {qualifiedTagLabel(props.tags, tag.tagId)}</em>}</For>
              </span>
            </button>
          </li>}
        </For>
      </ul>
      <Show when={hasMore()}>
        <button class="secondary" disabled={searching()} onClick={() => void search(true)}>
          {searching() ? 'Loading…' : 'Load more'}
        </button>
      </Show>
    </section>
  </div>
}
