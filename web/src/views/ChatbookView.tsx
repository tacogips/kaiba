import { Show, onCleanup, onMount, type JSX } from 'solid-js'
import { LeftPane } from '../panes/LeftPane'
import { ReaderPane } from '../panes/ReaderPane'
import { RightPane } from '../panes/RightPane'
import { NoteSearchPopup } from '../components/NoteSearchPopup'
import { BoardView } from './BoardView'
import { useApp } from '../state/appStore'

// The chatbook shell: a three-column grid whose fold state is expressed as data
// attributes so the layout never depends on selector tricks, plus the shared
// header, the search popup and the keyboard shortcuts.

export function ChatbookView(): JSX.Element {
  const app = useApp()

  onMount(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return
      const target = event.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA'
        || target.tagName === 'SELECT' || target.isContentEditable)) return
      if (event.key === '/') {
        event.preventDefault()
        app.setSearchOpen(true)
      } else if (event.key === '[') {
        event.preventDefault()
        app.toggleLeftPane()
      } else if (event.key === ']') {
        event.preventDefault()
        app.toggleRightPane()
      }
    }
    window.addEventListener('keydown', shortcut)
    onCleanup(() => window.removeEventListener('keydown', shortcut))
  })

  return (
    <div
      class="chatbook"
      data-left={app.state.pane.leftOpen ? 'open' : 'closed'}
      data-right={app.state.pane.rightOpen ? 'open' : 'closed'}
      data-view={app.state.route.kind === 'board' ? 'board' : 'reader'}
    >
      <a class="skip-link" href="#main-content">Skip to content</a>
      <header class="chatbook-head">
        <button type="button" class="brand-button" onClick={app.openHome}>
          <span class="brand-mark">K</span>
          <span class="brand-copy"><strong>Kaiba</strong><span>Note reader</span></span>
        </button>
        <div class="chatbook-head-actions">
          <span class="server-status" role="status" aria-live="polite">
            <span classList={{ dot: true, live: app.state.live }} />
            {app.state.live ? 'Live' : 'Offline'}
          </span>
          <button type="button" class="secondary" onClick={() => app.setSearchOpen(true)}>Search</button>
          <Show
            when={app.state.route.kind === 'board'}
            fallback={<button type="button" class="secondary" onClick={app.openBoard}>Board</button>}
          >
            <button type="button" class="secondary" onClick={app.openHome}>Reader</button>
          </Show>
          <button type="button" class="secondary" onClick={() => void app.refreshCatalog()}>Refresh</button>
        </div>
      </header>

      <Show when={app.state.error}>
        <div class="error-banner" role="alert">{app.state.error}
          <button type="button" class="secondary" onClick={() => void app.refreshCatalog()}>Retry</button>
        </div>
      </Show>
      <Show when={app.state.message}>
        <div class="notes-message" role="status" aria-live="polite">{app.state.message}
          <button type="button" aria-label="Dismiss message" onClick={() => app.setMessage('')}>×</button>
        </div>
      </Show>

      <Show when={app.state.route.kind === 'board'} fallback={
        <div class="chatbook-grid">
          <LeftPane />
          <ReaderPane />
          <RightPane />
        </div>
      }>
        <BoardView />
      </Show>

      <Show when={app.state.searchOpen}>
        <NoteSearchPopup
          client={app.client}
          tags={app.state.tags}
          onOpenNote={(noteId, notebookId) => app.openNote(noteId, notebookId)}
          onClose={() => app.setSearchOpen(false)}
        />
      </Show>
    </div>
  )
}
