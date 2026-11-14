import { Show, createEffect, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { LeftPane } from '../panes/LeftPane'
import { ReaderPane } from '../panes/ReaderPane'
import { RightPane } from '../panes/RightPane'
import { NoteSearchPopup } from '../components/NoteSearchPopup'
import { SearchView } from './SearchView'
import { ConfigView } from './ConfigView'
import { LoginView } from './LoginView'
import { useApp } from '../state/appStore'
import type { SearchMethod, SearchScope } from '../router'

// The chatbook shell: a three-column grid whose fold state is expressed as data
// attributes so the layout never depends on selector tricks, plus the shared
// header with the store-wide search form, the search popup and the keyboard
// shortcuts.

export function ChatbookView(): JSX.Element {
  const app = useApp()
  const [mobilePane, setMobilePane] = createSignal<MobilePane>('reader')

  const showMobilePane = (pane: MobilePane) => {
    if (pane === 'files' && !app.state.pane.leftOpen) app.toggleLeftPane()
    if (pane === 'details' && !app.state.pane.rightOpen) app.toggleRightPane()
    setMobilePane(pane)
  }

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

  const view = () => {
    switch (app.state.route.kind) {
      case 'search': return 'search'
      case 'config': return 'config'
      default: return 'reader'
    }
  }

  // Custom pane widths apply only while the pane is open — an inline custom
  // property would otherwise beat the stylesheet's collapsed rail width.
  const shellStyle = () => ({
    '--fs': String(app.state.settings.fontScale),
    ...(app.state.pane.leftOpen && app.state.pane.leftWidth !== undefined
      ? { '--pane-left': `${app.state.pane.leftWidth}px` }
      : {}),
    ...(app.state.pane.rightOpen && app.state.pane.rightWidth !== undefined
      ? { '--pane-right': `${app.state.pane.rightWidth}px` }
      : {}),
  })

  const shell = (): JSX.Element => (
    <div
      class="chatbook"
      style={shellStyle()}
      data-left={app.state.pane.leftOpen ? 'open' : 'closed'}
      data-right={app.state.pane.rightOpen ? 'open' : 'closed'}
      data-view={view()}
    >
      <a class="skip-link" href="#main-content">Skip to content</a>
      <header class="chatbook-head">
        <button type="button" class="brand-button" onClick={app.openHome}>
          <span class="brand-mark">K</span>
          <span class="brand-copy"><strong>Kaiba</strong><span>Note reader</span></span>
        </button>
        <HeaderSearch />
        <div class="chatbook-head-actions">
          <span class="server-status" role="status" aria-live="polite">
            <span classList={{ dot: true, live: app.state.live }} />
            {app.state.live ? 'Live' : 'Offline'}
          </span>
          <Show when={view() !== 'reader'}>
            <button type="button" class="secondary" onClick={() => {
              setMobilePane('reader')
              app.openReader()
            }}>Reader</button>
          </Show>
          <button type="button" class="secondary" onClick={app.openConfig}>Config</button>
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

      <Show when={view() === 'reader'}>
        <div class="chatbook-grid" data-mobile-pane={mobilePane()}>
          <LeftPane
            onClose={() => setMobilePane('reader')}
            onNavigate={() => setMobilePane('reader')}
          />
          <PaneSplitter side="left" />
          <ReaderPane />
          <PaneSplitter side="right" />
          <RightPane onClose={() => setMobilePane('reader')} />
          <MobilePaneNav active={mobilePane()} onSelect={showMobilePane} />
        </div>
      </Show>
      <Show when={view() === 'search'}>
        <SearchView />
      </Show>
      <Show when={view() === 'config'}>
        <ConfigView />
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

  // An unauthenticated host renders the login view alone. Mounting the shell
  // behind an error banner would show an empty tree that reads as an empty
  // store, and its Retry button would resend the same rejected request.
  return (
    <Show when={app.state.auth !== 'unauthenticated'} fallback={<LoginView />}>
      {shell()}
    </Show>
  )
}

type MobilePane = 'files' | 'reader' | 'details'

function MobilePaneNav(props: {
  active: MobilePane
  onSelect: (pane: MobilePane) => void
}): JSX.Element {
  const items: readonly { pane: MobilePane; label: string }[] = [
    { pane: 'files', label: 'Files' },
    { pane: 'reader', label: 'Reader' },
    { pane: 'details', label: 'Agent' },
  ]
  return (
    <nav class="mobile-pane-nav" aria-label="Mobile workspace">
      {items.map((item) => (
        <button
          type="button"
          classList={{ 'mobile-pane-button': true, active: props.active === item.pane }}
          aria-current={props.active === item.pane ? 'page' : undefined}
          onClick={() => props.onSelect(item.pane)}
        >{item.label}</button>
      ))}
    </nav>
  )
}

/** A draggable divider beside a side pane: dragging it resizes the pane. The
 * new width persists with the fold state. Inert while the pane is collapsed. */
function PaneSplitter(props: { side: 'left' | 'right' }): JSX.Element {
  const app = useApp()
  const open = () => props.side === 'left' ? app.state.pane.leftOpen : app.state.pane.rightOpen

  const down = (event: PointerEvent & { currentTarget: HTMLElement }) => {
    if (!open()) return
    const pane = props.side === 'left'
      ? event.currentTarget.previousElementSibling
      : event.currentTarget.nextElementSibling
    if (!(pane instanceof HTMLElement)) return
    event.preventDefault()
    const handle = event.currentTarget
    const startX = event.clientX
    const startWidth = pane.getBoundingClientRect().width
    handle.setPointerCapture(event.pointerId)
    const move = (moveEvent: PointerEvent) => {
      const delta = moveEvent.clientX - startX
      app.setPaneWidth(props.side, props.side === 'left' ? startWidth + delta : startWidth - delta)
    }
    const finish = () => {
      handle.removeEventListener('pointermove', move)
      handle.removeEventListener('pointerup', finish)
      handle.removeEventListener('pointercancel', finish)
    }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', finish)
    handle.addEventListener('pointercancel', finish)
  }

  return (
    <div
      classList={{ 'pane-splitter': true, inert: !open() }}
      role="separator"
      aria-orientation="vertical"
      aria-label={`Resize the ${props.side} pane`}
      onPointerDown={down}
      onDblClick={() => app.resetPaneWidths()}
    />
  )
}

/** The header search form: query, scope (all notebooks / the open notebook)
 * and method (agentic by default, or grep). Submitting navigates to the
 * search results screen. */
function HeaderSearch(): JSX.Element {
  const app = useApp()
  const [query, setQuery] = createSignal('')
  const [scope, setScope] = createSignal<SearchScope>('all')
  const [method, setMethod] = createSignal<SearchMethod>('agentic')

  // Landing on (or navigating within) the search screen reflects the route
  // back into the form so the fields show what is being searched.
  createEffect(() => {
    const route = app.state.route
    if (route.kind !== 'search') return
    setQuery(route.query)
    setScope(route.scope)
    setMethod(route.method)
  })

  const submit = (event: Event) => {
    event.preventDefault()
    const trimmed = query().trim()
    if (trimmed.length === 0) return
    app.openSearch(trimmed, scope(), method())
  }

  return (
    <form class="header-search" role="search" onSubmit={submit}>
      <label>
        <span class="sr-only">Search query</span>
        <input
          type="search"
          placeholder="Search notes and memos"
          value={query()}
          onInput={(event) => setQuery(event.currentTarget.value)}
        />
      </label>
      <label>
        <span class="sr-only">Search scope</span>
        <select
          value={scope()}
          onChange={(event) => setScope(event.currentTarget.value as SearchScope)}
        >
          <option value="all">All notebooks</option>
          <option value="notebook" disabled={!app.state.notebookId}>This notebook</option>
        </select>
      </label>
      <label>
        <span class="sr-only">Search method</span>
        <select
          value={method()}
          onChange={(event) => setMethod(event.currentTarget.value as SearchMethod)}
        >
          <option value="agentic">Agentic</option>
          <option value="grep">Grep</option>
        </select>
      </label>
      <button type="submit" class="secondary" disabled={query().trim().length === 0}>Search</button>
    </form>
  )
}
