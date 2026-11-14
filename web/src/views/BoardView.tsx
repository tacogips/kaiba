import { For, Show, createMemo, createSignal, onMount, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import { NotebookProgressController } from '../notes/controller'
import {
  boardColumnIndex,
  defaultStatusSet,
  progressLabelFor,
  statusLabel,
} from '../notes/kanban'
import type { KanbanStatusSet, Notebook } from '../notes/types'

// Kanban board over the notebook catalog, reachable at `#/board`. It shares the
// store's notebook list and moves a notebook by writing its progress; the lock
// keeps the board read-only until the reader deliberately unlocks it.

const boardLockStorageKey = 'kaiba-note-board-lock'

export function BoardView(): JSX.Element {
  const app = useApp()
  const [statusSet, setStatusSet] = createSignal<KanbanStatusSet>(defaultStatusSet)
  const [locked, setLocked] = createSignal(readLock())
  const [dragging, setDragging] = createSignal<string>()
  const [message, setMessage] = createSignal('')
  const [progressById, setProgressById] = createSignal<Record<string, string>>({})

  const controller = new NotebookProgressController(
    {
      setProgress: (notebookId, progress) => app.client.setProgress(notebookId, progress),
      readNotebook: (notebookId) => app.client.notebook(notebookId),
    },
    (updated, mutationError) => {
      setProgressById((current) => ({ ...current, [updated.notebookId]: updated.progress }))
      if (mutationError) setMessage(`Progress reconciled to the server value: ${mutationError}`)
    },
  )

  onMount(() => {
    void (async () => {
      try {
        const effective = await app.client.effectiveKanbanStatuses()
        if (effective.statuses.length > 0) setStatusSet(effective)
      } catch (statusError) {
        setMessage(`Using the default status set: ${errorMessage(statusError)}`)
      }
    })()
  })

  const statuses = createMemo(() => statusSet().statuses)
  const progressOf = (notebook: Notebook) => progressById()[notebook.notebookId] ?? notebook.progress
  const columns = createMemo(() => {
    const values = statuses()
    const assignments = new Map<string, Notebook[]>(values.map((status) => [status.name, []]))
    for (const notebook of app.state.notebooks) {
      const status = values[boardColumnIndex(progressOf(notebook), values)]
      if (status) assignments.get(status.name)?.push(notebook)
    }
    return assignments
  })

  const toggleLock = () => {
    const next = !locked()
    setLocked(next)
    try {
      localStorage.setItem(boardLockStorageKey, next ? 'locked' : 'unlocked')
    } catch {
      // Persistence is best-effort; the toggle still applies to this session.
    }
  }

  const move = async (notebook: Notebook, progress: string) => {
    setMessage('')
    await controller.move({ ...notebook, progress: progressOf(notebook) }, progress)
  }

  return (
    <main class="board-view" id="main-content" tabindex="-1">
      <header class="board-head">
        <div>
          <span class="eyebrow">BOARD</span>
          <h1>Notebooks by progress</h1>
        </div>
        <div class="board-actions">
          <button
            type="button"
            class="secondary lock-toggle"
            aria-pressed={locked()}
            onClick={toggleLock}
          >{locked() ? 'Locked' : 'Editable'}</button>
          <button type="button" class="secondary" onClick={() => void app.refreshCatalog()}>Refresh</button>
          <button type="button" onClick={app.openHome}>Back to reader</button>
        </div>
      </header>
      <Show when={message()}>
        <div class="notes-message" role="status" aria-live="polite">{message()}
          <button type="button" aria-label="Dismiss message" onClick={() => setMessage('')}>×</button>
        </div>
      </Show>
      <div class="notebook-board" style={{ '--board-columns': statuses().length }}>
        <For each={statuses()}>{(status) => {
          const column = () => columns().get(status.name) ?? []
          return <section
            class={`board-column cat-${status.category}`}
            aria-label={`${statusLabel(status)} notebooks`}
            onDragOver={(event) => { if (!locked()) event.preventDefault() }}
            onDrop={(event) => {
              if (locked()) return
              const draggedId = event.dataTransfer?.getData('text/plain')
              setDragging(undefined)
              const notebook = app.state.notebooks.find((item) => item.notebookId === draggedId)
              if (notebook && progressOf(notebook) !== status.name) void move(notebook, status.name)
            }}
          >
            <header><strong>{statusLabel(status)}</strong><span>{column().length}</span></header>
            <div class="board-cards">
              <For each={column()}>{(notebook) =>
                <article
                  class="board-card"
                  draggable={!locked()}
                  aria-grabbed={dragging() === notebook.notebookId}
                  onDragStart={(event) => {
                    if (locked()) { event.preventDefault(); return }
                    event.dataTransfer?.setData('text/plain', notebook.notebookId)
                    setDragging(notebook.notebookId)
                  }}
                  onDragEnd={() => setDragging(undefined)}
                >
                  <button
                    type="button"
                    class="board-card-open"
                    onClick={() => app.openNotebook(notebook.notebookId)}
                  >
                    <strong>{notebook.title}</strong>
                    <span class="board-card-meta">
                      {progressLabelFor(progressOf(notebook), statuses())}
                    </span>
                  </button>
                  <label>
                    <span class="sr-only">Move {notebook.title} to progress</span>
                    <select
                      value={progressOf(notebook)}
                      disabled={locked()}
                      onChange={(event) => void move(notebook, event.currentTarget.value)}
                    >
                      <For each={statuses()}>{(option) =>
                        <option value={option.name}>{statusLabel(option)}</option>}
                      </For>
                    </select>
                  </label>
                </article>}
              </For>
            </div>
          </section>
        }}</For>
      </div>
    </main>
  )
}

function readLock(): boolean {
  try {
    return localStorage.getItem(boardLockStorageKey) !== 'unlocked'
  } catch {
    return true
  }
}
