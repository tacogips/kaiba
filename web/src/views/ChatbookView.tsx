import { Show, createEffect, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { LeftPane } from '../panes/LeftPane'
import { ReaderPane } from '../panes/ReaderPane'
import { RightPane } from '../panes/RightPane'
import { NoteSearchPopup } from '../components/NoteSearchPopup'
import { SearchView } from './SearchView'
import { ConfigView } from './ConfigView'
import { LoginView } from './LoginView'
import { WorkspaceShortcuts, shortcutLabel, type WorkspaceCommand } from '../components/WorkspaceShortcuts'
import { WorkspaceIcon } from '../components/WorkspaceIcon'
import { useApp } from '../state/appStore'
import { formatRoute } from '../router'
import type { RightTab } from '../state/paneState'
import type { NotebookId } from '../notes/ids'
import { AgentFooter } from '../components/AgentFooter'

// The chatbook shell: a three-column grid whose fold state is expressed as data
// attributes so the layout never depends on selector tricks, plus the shared
// header with the store-wide search form, the search popup and the keyboard
// shortcuts.

export function ChatbookView(): JSX.Element {
  const app = useApp()
  const [mobilePane, setMobilePane] = createSignal<MobilePane>('reader')
  const [agentConversation, setAgentConversation] = createSignal<NotebookId>()
  const [pendingNavigation, setPendingNavigation] = createSignal<{ ready: () => boolean; run: () => void }>()
  // Hash navigation completes asynchronously in the browser and native web view.
  // Defer destination actions until the route has mounted its controls.
  const afterNavigation = (ready: () => boolean, navigate: () => void, run: () => void) => {
    setPendingNavigation(undefined)
    if (ready()) { navigate(); run(); return }
    setPendingNavigation({ ready, run })
    navigate()
  }
  createEffect(() => {
    const pending = pendingNavigation()
    if (!pending?.ready()) return
    queueMicrotask(() => {
      if (pendingNavigation() !== pending) return
      setPendingNavigation(undefined)
      pending.run()
    })
  })
  onCleanup(() => setPendingNavigation(undefined))
  const openAgentConversation = (id: NotebookId) => {
    setAgentConversation(id)
    showDetails('memo')
  }
  createEffect(() => {
    // Navigation reveals its destination even when Learn was the last mobile pane.
    formatRoute(app.state.route)
    setMobilePane('reader')
  })

  const showMobilePane = (pane: MobilePane) => {
    if (pane === 'files' && !app.state.pane.leftOpen) app.toggleLeftPane()
    if (pane === 'details' && !app.state.pane.rightOpen) app.toggleRightPane()
    setMobilePane(pane)
  }

  const inReader = (run: () => void) => afterNavigation(
    () => app.state.route.kind !== 'config' && app.state.route.kind !== 'search', app.openReader, run)
  const showDetails = (tab: RightTab, then?: () => void) => inReader(() => afterNavigation(
    () => !app.tagPaneTagId(), app.closeTagPane, () => {
      app.setRightTab(tab)
      showMobilePane('details')
      then?.()
    }))

  const focus = (selector: string) => queueMicrotask(() => document.querySelector<HTMLElement>(selector)?.focus())
  const newNotebook = () => afterNavigation(() => app.state.route.kind === 'home', app.openHome, () => {
    setMobilePane('reader'); focus('.new-notebook-editor textarea')
  })
  const browseNotebooks = () => inReader(() => showMobilePane('files'))
  const agentChat = () => showDetails('memo', () => focus('.pane-right .chat textarea'))
  const commands: WorkspaceCommand[] = [
    { label: 'New notebook', key: 'n', run: newNotebook },
    { label: 'Notebooks', key: '1', shift: true, run: browseNotebooks },
    { label: 'Toggle tree / timeline', key: 't', shift: true, run: () => {
      app.setNotebookView(app.state.pane.notebookView === 'tree' ? 'timeline' : 'tree')
      browseNotebooks()
    } },
    { label: 'Quick switcher', key: 'p', run: () => app.setSearchOpen(true) },
    { label: 'AI', key: 'a', shift: true, run: agentChat },
    { label: 'Ask AI', key: 'j', run: () => {
      document.querySelector<HTMLButtonElement>('.agent-footer [aria-label="Ask AI"][aria-expanded="false"]')?.click()
      focus('.agent-footer textarea')
    } },
    { label: 'New chat', key: 'j', shift: true, run: () => {
      showDetails('memo', () => queueMicrotask(() => {
        document.querySelector<HTMLButtonElement>('.pane-right [aria-label="New chat"]:not(:disabled)')?.click()
        focus('.pane-right .chat textarea')
      }))
    } },
    { label: 'Tags', key: '2', shift: true, run: () => showDetails('info') },
    { label: 'Links', key: '3', shift: true, run: () => showDetails('links') },
    { label: 'History', key: '4', shift: true, run: () => showDetails('history') },
    { label: 'Settings', key: ',', run: app.openConfig },
    { label: 'Toggle library pane', key: 'b', run: app.toggleLeftPane },
    { label: 'Toggle details pane', key: 'b', shift: true, run: app.toggleRightPane },
    { label: 'Add a note', key: 'n', shift: true, run: () => inReader(() => {
      setMobilePane('reader')
      queueMicrotask(() => {
        document.querySelector<HTMLButtonElement>('.note-capture > button')?.click()
        focus('main .note-capture textarea')
      })
    }) },
    { label: 'Save writing', key: 's', run: () => {
      const activeForm = document.activeElement?.closest('form')
      const form = activeForm?.matches('main .note-capture form, main form.note-capture, main .note-editor form') ? activeForm : document.querySelector<HTMLFormElement>('main .note-capture form, main form.note-capture, main .note-editor form')
      form?.querySelector<HTMLButtonElement>('button[type="submit"]:not(:disabled)')?.click()
    } },
    { label: 'Keyboard shortcuts', key: '/', run: () => document.querySelector<HTMLButtonElement>('[aria-label="Keyboard shortcuts"]')?.click() },
  ]
  const hint = (label: string) => `${label} (${shortcutLabel(commands.find((command) => command.label === label)!)})`

  onMount(() => {
    const shortcut = (event: KeyboardEvent) => {
      if (app.state.auth === 'unauthenticated' || app.state.searchOpen || event.defaultPrevented
        || event.isComposing || event.repeat || document.querySelector('dialog[open], [role="dialog"]')) return
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
    const protectDrafts = (event: BeforeUnloadEvent) => {
      if (!app.writingDrafts.hasUnsavedChanges()) return
      event.preventDefault()
      event.returnValue = true
    }
    window.addEventListener('beforeunload', protectDrafts)
    onCleanup(() => {
      window.removeEventListener('keydown', shortcut)
      window.removeEventListener('beforeunload', protectDrafts)
    })
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
      <div class="chatbook-head workspace-menu">
        <nav class="workspace-tools" aria-label="Workspace">
          <button type="button" class="workspace-icon" aria-label="New notebook" title={hint('New notebook')} onClick={newNotebook}><WorkspaceIcon name="edit" /></button>
          <button type="button" class="workspace-icon" aria-label="Notebooks" title={hint('Notebooks')} onClick={browseNotebooks}><WorkspaceIcon name="files" /></button>
          <button type="button" class="workspace-icon" aria-label="Quick switcher" title="Quick switcher (⌘/Ctrl P)" onClick={() => app.setSearchOpen(true)}><WorkspaceIcon name="search" /></button>
          <button type="button" class="workspace-icon" aria-label="AI" title={hint('AI')} onClick={agentChat}><WorkspaceIcon name="ai" /></button>
          <button type="button" class="workspace-icon" aria-label="Tags" title={hint('Tags')} onClick={() => showDetails('info')}><WorkspaceIcon name="tags" /></button>
          <button type="button" class="workspace-icon" aria-label="Links" title={hint('Links')} onClick={() => showDetails('links')}><WorkspaceIcon name="links" /></button>
        </nav>
        <div class="chatbook-head-actions">
          <WorkspaceShortcuts commands={commands} blocked={() => app.state.auth === 'unauthenticated' || app.state.searchOpen} />
          <button type="button" class="workspace-icon" aria-label="Settings" title={hint('Settings')} onClick={app.openConfig}><WorkspaceIcon name="settings" /></button>
        </div>
      </div>

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
          <ReaderPane
            onStudy={() => showMobilePane('details')}
            onBrowseNotebooks={() => showMobilePane('files')}
          />
          <PaneSplitter side="right" />
          <RightPane onClose={() => setMobilePane('reader')} conversationId={agentConversation()} onConversation={openAgentConversation} />
        </div>
      </Show>
      <Show when={view() === 'search'}>
        <SearchView />
      </Show>
      <Show when={view() === 'config'}>
        <ConfigView />
      </Show>

      <AgentFooter onConversation={openAgentConversation} />
      <Show when={app.state.searchOpen}>
        <NoteSearchPopup
          client={app.client}
          tags={app.state.tags}
          onOpenNote={(noteId, notebookId) => {
            app.openNoteWithReturn(noteId, notebookId)
            setMobilePane('reader')
          }}
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
