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
import { stagePageRegion } from '../notes/stagePageRegion'
import type { Note } from '../notes/types'
import type { RightTab } from '../state/paneState'
import type { NotebookId } from '../notes/ids'
import { DocumentImportPopup } from '../components/DocumentImportPopup'
import { TaskIndicator } from '../components/TaskIndicator'
import { TasksView } from './TasksView'
import { ToastNotice } from '../components/ToastNotice'
import { FastNotesView } from './FastNotesView'
import { AgentFooter } from '../components/AgentFooter'
import { WorkspaceVimNavigation } from '../components/WorkspaceVimNavigation'
import '../workspace-actions.css'

// The chatbook shell: a three-column grid whose fold state is expressed as data
// attributes so the layout never depends on selector tricks, plus the shared
// header with the store-wide search form, the search popup and the keyboard
// shortcuts.

export function ChatbookView(): JSX.Element {
  const app = useApp()
  const [importOpen, setImportOpen] = createSignal(false)
  let createMenu!: HTMLDetailsElement
  const [mobilePane, setMobilePane] = createSignal<MobilePane>('reader')
  const [compact, setCompact] = createSignal(window.innerWidth <= 600)
  const [footerConversation, setFooterConversation] = createSignal<{ notebookId?: NotebookId }>()
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
    setFooterConversation({ notebookId: id })
    setMobilePane('reader')
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
    () => app.state.route.kind !== 'config' && app.state.route.kind !== 'search' && app.state.route.kind !== 'tasks', app.openReader, run)
  const showDetails = (tab: RightTab, then?: () => void) => inReader(() => afterNavigation(
    () => !app.tagPaneTagId(), app.closeTagPane, () => {
      app.setRightTab(tab)
      showMobilePane('details')
      then?.()
    }))

  const focus = (selector: string) => queueMicrotask(() => document.querySelector<HTMLElement>(selector)?.focus())
  const newNotebook = () => afterNavigation(() => app.state.route.kind === 'home', app.openHome, () => {
    void app.notebookAutosave.startNew().then(() => { setMobilePane('reader'); focus('.new-notebook-editor textarea') })
  })
  const browseNotebooks = () => {
    if (app.state.route.kind === 'fast') {
      const notebookId = app.state.notebookId
      afterNavigation(() => app.state.route.kind !== 'fast', () => notebookId ? app.openNotebook(notebookId) : app.openHome(), () => showMobilePane('files'))
    } else inReader(() => showMobilePane('files'))
  }
  const libraryVisible = () => app.state.pane.leftOpen && (!compact() || mobilePane() === 'files')
  const detailsVisible = () => app.state.pane.rightOpen && (!compact() || mobilePane() === 'details')
  const toggleLibrary = () => {
    if (app.state.route.kind === 'fast') { browseNotebooks(); return }
    inReader(() => {
    if (libraryVisible()) {
      if (!compact()) app.toggleLeftPane()
      setMobilePane('reader')
    } else showMobilePane('files')
    })
  }
  const toggleDetails = () => inReader(() => {
    if (detailsVisible()) {
      if (!compact()) app.toggleRightPane()
      setMobilePane('reader')
    } else showMobilePane('details')
  })
  const agentChat = () => {
    setMobilePane('reader')
    setFooterConversation({})
    focus('.agent-footer textarea')
  }
  const captureRegion = async (note: Note, file: File) => {
    if (await stagePageRegion(app, note, file)) agentChat()
  }
  const focusPane = (pane: 'left' | 'right' | 'bottom' | 'reader' | 'next') => {
    if (pane === 'next') {
      const order = ['left', 'reader', 'right', 'bottom'] as const
      const selectors = ['.pane-left', 'main.reader', '.pane-right', '.agent-footer']
      const index = selectors.findIndex((selector) => document.activeElement?.closest(selector))
      focusPane(order[(index + 1) % order.length]!); return
    }
    if (pane === 'bottom') { setMobilePane('reader'); window.dispatchEvent(new Event('kaiba-focus-ai')); return }
    if (pane === 'left') { browseNotebooks(); focus('.pane-left button'); return }
    if (pane === 'right') { showDetails(app.state.pane.rightTab, () => focus('.pane-right button')); return }
    inReader(() => {
      setMobilePane('reader')
      queueMicrotask(() => (document.querySelector<HTMLElement>('main .notebook-source:not([hidden]):not(:disabled)')
        ?? document.querySelector<HTMLElement>('main.reader'))?.focus())
    })
  }
  const addNote = () => {
    if (app.state.route.kind === 'fast') {
      afterNavigation(() => app.state.route.kind === 'fast' && !app.state.route.noteId, () => app.openFastNotes(), () => focus('[aria-label="Write a quick note"]'))
      return
    }
    inReader(() => {
    setMobilePane('reader')
    queueMicrotask(() => {
      const notebookSource = document.querySelector<HTMLTextAreaElement>('main .notebook-source:not([hidden])')
      if (notebookSource) {
        notebookSource.value += '\n\n<><>\n\n'
        notebookSource.dispatchEvent(new Event('input', { bubbles: true }))
        notebookSource.focus(); notebookSource.setSelectionRange(notebookSource.value.length, notebookSource.value.length)
        return
      }
      const addDraftNote = document.querySelector<HTMLButtonElement>('main [aria-label="Add a note to this draft"]')
      if (addDraftNote) { addDraftNote.click(); return }
      document.querySelector<HTMLButtonElement>('main .note-capture > button')?.click()
      focus('main .note-capture textarea')
    })
    })
  }
  const openImport = () => { if (createMenu) createMenu.open = false; setImportOpen(true) }
  const commands: WorkspaceCommand[] = [
    { label: 'New notebook', key: 'n', run: newNotebook },
    { label: 'Notebooks', key: '1', shift: true, run: browseNotebooks },
    { label: 'Toggle tree / timeline', key: 't', shift: true, run: () => {
      app.setNotebookView(app.state.pane.notebookView === 'tree' ? 'timeline' : 'tree')
      browseNotebooks()
    } },
    { label: 'Quick switcher', key: 'p', run: () => app.setSearchOpen(true) },
    { label: 'AI', key: 'a', shift: true, run: agentChat },
    { label: 'Ask AI', key: 'j', run: agentChat },
    { label: 'New chat', key: 'j', shift: true, run: () => {
      agentChat()
      queueMicrotask(() => {
        document.querySelector<HTMLButtonElement>('.agent-footer [aria-label="New chat"]:not(:disabled)')?.click()
        focus('.agent-footer textarea')
      })
    } },
    { label: 'Tags', key: '2', shift: true, run: () => showDetails('tags') },
    { label: 'Backlinks', key: '3', shift: true, run: () => showDetails('links') },
    { label: 'AI conversations', key: '4', shift: true, run: () => showDetails('history') },
    { label: 'Settings', key: ',', run: app.openConfig },
    { label: 'Toggle library pane', key: 'b', run: toggleLibrary },
    { label: 'Toggle details pane', key: 'b', shift: true, run: toggleDetails },
    { label: 'Add a note', key: 'n', shift: true, run: addNote },
    { label: 'Save writing', key: 's', run: () => {
      const notebookForm = document.querySelector<HTMLFormElement>('main .notebook-writing-form')
      if (notebookForm) { notebookForm.requestSubmit(); return }
      const activeForm = document.activeElement?.closest('form')
      const form = activeForm?.matches('main .note-capture form, main form.note-capture, main .note-editor form') ? activeForm : document.querySelector<HTMLFormElement>('main .note-capture form, main form.note-capture, main .note-editor form')
      form?.querySelector<HTMLButtonElement>('button[type="submit"]:not(:disabled)')?.click()
    } },
    { label: 'Keyboard shortcuts', key: '/', run: () => document.querySelector<HTMLButtonElement>('[aria-label="Keyboard shortcuts"]')?.click() },
  ]
  const hint = (label: string) => `${label} (${shortcutLabel(commands.find((command) => command.label === label)!)})`

  onMount(() => {
    const resize = () => setCompact(window.innerWidth <= 600)
    window.addEventListener('resize', resize)
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
    const protectWork = (event: BeforeUnloadEvent) => {
      if (!app.writingDrafts.hasUnsavedChanges() && app.ocrTasks.active().length === 0 && !app.settingsSave?.pending()) return
      event.preventDefault()
      event.returnValue = true
    }
    window.addEventListener('beforeunload', protectWork)
    onCleanup(() => {
      window.removeEventListener('resize', resize)
      window.removeEventListener('keydown', shortcut)
      window.removeEventListener('beforeunload', protectWork)
    })
  })

  const view = () => {
    switch (app.state.route.kind) {
      case 'tasks': return 'tasks'
      case 'fast': return 'fast'
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
      <WorkspaceVimNavigation blocked={() => app.state.auth === 'unauthenticated' || app.state.searchOpen}
        onWrite={() => inReader(() => { setMobilePane('reader'); window.dispatchEvent(new Event('kaiba-write-notebook')) })} onFocus={focusPane} />
      <div class="chatbook-head workspace-menu">
        <nav class="workspace-tools" aria-label="Workspace">
          <details class="workspace-create-menu" ref={createMenu} onKeyDown={(event) => { if (event.key === 'Escape') createMenu.open = false }}>
            <summary aria-label="Workspace menu" title="Workspace menu: new notebook and document import"><WorkspaceIcon name="more" /></summary>
            <div class="workspace-create-actions" role="group" aria-label="Notebook actions">
              <button type="button" aria-label="New notebook" title={hint('New notebook')}
                onClick={() => { createMenu.open = false; newNotebook() }}><WorkspaceIcon name="edit" />New notebook</button>
              <button type="button" onClick={openImport}><WorkspaceIcon name="file" />Import PDF or image…</button>
            </div>
          </details>
          <button type="button" class="workspace-icon" aria-label="Fast notes" title="Fast notes: newest created first" aria-pressed={view() === 'fast'} onClick={() => app.openFastNotes()}><WorkspaceIcon name="timeline" /></button>
          <button type="button" class="workspace-icon" aria-label="Notebooks" title={view() === 'fast' ? 'Reference view: notebook library' : hint('Toggle library pane')} aria-expanded={view() !== 'fast' && libraryVisible()} onClick={toggleLibrary}><WorkspaceIcon name="files" /></button>
          <button type="button" class="workspace-icon" aria-label="Quick switcher" title="Quick switcher (⌘/Ctrl P)" onClick={() => app.setSearchOpen(true)}><WorkspaceIcon name="search" /></button>
          <button type="button" class="workspace-icon" aria-label="AI" title={`${hint('AI')}: Discussion for the selected page or notebook`} onClick={agentChat}><WorkspaceIcon name="ai" /></button>
        </nav>
        <div class="chatbook-head-actions">
          <TaskIndicator />
          <Show when={view() !== 'fast' || (app.state.route.kind === 'fast' && app.state.route.noteId)}><button type="button" class="workspace-icon" aria-label="Toggle details pane" title={hint('Toggle details pane')}
            aria-expanded={detailsVisible()} onClick={toggleDetails}><WorkspaceIcon name="panelRight" /></button></Show>
          <WorkspaceShortcuts commands={commands} blocked={() => app.state.auth === 'unauthenticated' || app.state.searchOpen} />
          <button type="button" class="workspace-icon" aria-label="Settings" title={hint('Settings')} onClick={app.openConfig}><WorkspaceIcon name="settings" /></button>
        </div>
      </div>

      <Show when={app.state.error}>
        <ToastNotice message={app.state.error} severity="error" onDismiss={app.dismissError} onRetry={() => void app.refreshCatalog()} />
      </Show>
      <Show when={app.state.message}>
        <ToastNotice message={app.state.message} severity={app.state.messageSeverity} onDismiss={() => app.setMessage('')} />
      </Show>

      <Show when={view() === 'reader'}>
        <div class="chatbook-grid" data-mobile-pane={mobilePane()}>
          <LeftPane
            onClose={() => setMobilePane('reader')}
            onNavigate={() => setMobilePane('reader')}
          />
          <PaneSplitter side="left" />
          <ReaderPane
            onCaptureRegion={captureRegion}
            onStudy={() => app.state.pane.rightTab === 'memo' ? agentChat() : showMobilePane('details')}
            onBrowseNotebooks={() => showMobilePane('files')}
          />
          <PaneSplitter side="right" />
          <RightPane onClose={() => setMobilePane('reader')} onConversation={openAgentConversation} />
        </div>
      </Show>
      <Show when={view() === 'fast'}>
        <div class="chatbook-grid fast-notes-grid" classList={{ 'has-selected-note': app.state.route.kind === 'fast' && Boolean(app.state.route.noteId) }} data-mobile-pane={mobilePane()}>
          <FastNotesView />
          <Show when={app.state.route.kind === 'fast' && app.state.route.noteId}>
            <PaneSplitter side="right" />
            <RightPane onClose={() => setMobilePane('reader')} onConversation={openAgentConversation} />
          </Show>
        </div>
      </Show>
      <Show when={view() === 'tasks'}><TasksView /></Show>
      <Show when={view() === 'search'}>
        <SearchView />
      </Show>
      <Show when={view() === 'config'}>
        <ConfigView />
      </Show>

      <AgentFooter onConversation={openAgentConversation} conversationRequest={footerConversation()} />
      <Show when={importOpen()}><DocumentImportPopup onClose={() => setImportOpen(false)} /></Show>
      <Show when={app.state.searchOpen}>
        <NoteSearchPopup
          client={app.client}
          tags={app.state.tags}
          notebooks={app.state.notebooks}
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
      title={`Drag to resize the ${props.side} pane; double-click to reset pane widths`}
      onPointerDown={down}
      onDblClick={() => app.resetPaneWidths()}
    />
  )
}
