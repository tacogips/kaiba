import { For, Show, createMemo, createSignal, type JSX } from 'solid-js'
import { formatTimestamp } from '../notes/format'
import { diaryNotebooks, notebookCategories, notebookPreview } from '../notes/notebookList'
import { qualifiedTagLabel } from '../notes/tree'
import { useApp } from '../state/appStore'

export function NotebookListTab(): JSX.Element {
  const app = useApp()
  const [tagId, setTagId] = createSignal<string>()
  const notebooks = createMemo(() => diaryNotebooks(app.state.notebooks, tagId()))
  const categories = createMemo(() => {
    const byId = new Map(
      diaryNotebooks(app.state.notebooks)
        .flatMap(notebookCategories)
        .map((assignment) => [assignment.tag.tagId, assignment.tag] as const),
    )
    return [...byId.values()].sort((left, right) =>
      left.name.localeCompare(right.name) || left.tagId.localeCompare(right.tagId))
  })

  return (
    <section class="notebook-list-view" aria-label="Recent notebook writing">
      <header class="notebook-list-head">
        <div>
          <span class="eyebrow">Diary</span>
          <h1>Recent writing</h1>
          <p>Write without filing first. Your latest notebooks stay visible here while tags organize them.</p>
        </div>
        <span class="notebook-list-count">{notebooks().length} notebook{notebooks().length === 1 ? '' : 's'}</span>
      </header>

      <Show when={categories().length > 0}>
        <div class="notebook-list-filters" role="group" aria-label="Filter recent writing by category">
          <button
            type="button"
            classList={{ 'category-filter': true, active: !tagId() }}
            aria-pressed={!tagId()}
            onClick={() => setTagId(undefined)}
          >All</button>
          <For each={categories()}>{(tag) =>
            <button
              type="button"
              classList={{ 'category-filter': true, active: tagId() === tag.tagId }}
              aria-pressed={tagId() === tag.tagId}
              onClick={() => setTagId(tag.tagId)}
            >#{qualifiedTagLabel(app.state.tags, tag.tagId)}</button>}
          </For>
        </div>
      </Show>

      <Show when={app.state.loading && app.state.notebooks.length === 0}>
        <div class="loading-state"><span class="loader" />Loading recent writing…</div>
      </Show>
      <Show when={!app.state.loading && notebooks().length === 0}>
        <div class="empty-state notebook-list-empty">
          <strong>{tagId() ? 'No notebooks in this category' : 'No notebooks yet'}</strong>
          <p>{tagId() ? 'Choose another tag to widen the view.' : 'Your writing will appear here in chronological order.'}</p>
        </div>
      </Show>

      <div class="notebook-card-list">
        <For each={notebooks()}>{(notebook) => {
          const assignments = () => notebookCategories(notebook)
          return <button
            type="button"
            class="notebook-card"
            onClick={() => app.openNotebook(notebook.notebookId)}
          >
            <span class="notebook-card-main">
              <strong>{notebook.title}</strong>
              <span class="notebook-card-preview">{notebookPreview(notebook.firstNotePreview)}</span>
            </span>
            <span class="notebook-card-meta">
              <time datetime={notebook.updatedAt}>{formatTimestamp(notebook.updatedAt)}</time>
              <Show when={notebook.noteCount !== undefined && notebook.noteCount !== null}>
                <span>{notebook.noteCount} note{notebook.noteCount === 1 ? '' : 's'}</span>
              </Show>
              <Show when={notebook.readOnly}><span>Read-only</span></Show>
            </span>
            <Show when={assignments().length > 0}>
              <span class="notebook-card-tags" aria-label="Categories">
                <For each={assignments()}>{(assignment) =>
                  <span class="folder-chip" title={`${assignment.provenance} classification`}>
                    #{qualifiedTagLabel(app.state.tags, assignment.tag.tagId)}
                    <em class="tag-provenance">{assignment.provenance}</em>
                  </span>}
                </For>
              </span>
            </Show>
          </button>
        }}</For>
      </div>
    </section>
  )
}
