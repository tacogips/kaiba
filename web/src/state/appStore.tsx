import { createContext, onCleanup, useContext, type JSX } from 'solid-js'
import { createStore, produce } from 'solid-js/store'
import { NoteGraphQLClient, notebookPageLimit } from '../notes/client'
import { subscribeNoteEvents } from '../notes/events'
import { loadNotebookPages } from '../notes/paging'
import type { Note, Notebook, NoteTag, NoteTagClass } from '../notes/types'
import {
  browserRouterEnvironment,
  formatRoute,
  navigate,
  parseRoute,
  rememberReaderRoute,
  routeTagId,
  subscribeRoute,
  withConversation,
  withTag,
  type Route,
  type RouterEnvironment,
  type SearchMethod,
  type SearchScope,
} from '../router'
import { popReturn, pushReturn } from './returnStack'
import {
  browserPaneStorage,
  clampPaneWidth,
  readPaneState,
  withLeftTab,
  withRightTab,
  writePaneState,
  type LeftTab,
  type PaneState,
  type PaneStateStorage,
  type RightTab,
} from './paneState'
import {
  clampFontScale,
  defaultWebSettings,
  parseWebSettings,
  serializeWebSettings,
  webSettingsKey,
  type WebAppSettings,
} from '../notes/settings'

// The single owner of selection, pane layout, the note catalog and the note
// events subscription. Panes read from here instead of receiving props drilled
// down from a view, and every live update enters through one feed.

export interface AppState {
  route: Route
  loading: boolean
  error: string
  message: string
  /** False only once the events feed has reported itself unavailable; the first
   * long poll on a quiet store can stay open for its whole timeout, which is
   * not an outage. */
  live: boolean
  tags: NoteTag[]
  tagClasses: NoteTagClass[]
  notebooks: Notebook[]
  notesByNotebook: Record<string, Note[]>
  notebookId?: string
  noteId?: string
  note?: Note
  noteLoading: boolean
  expandedFolders: string[]
  expandedNotebooks: string[]
  activeHeadingId: string
  pane: PaneState
  /** Bumped per notebook whenever the events feed reports a change to it, so a
   * pane can refetch exactly what it shows. */
  notebookRevisions: Record<string, number>
  /** Bumped whenever the catalog is reloaded, so a pane that lists notebooks
   * (the chat tab's conversations) can follow store-wide changes. */
  catalogRevision: number
  searchOpen: boolean
  /** App settings from the store's sqlite (`app_settings`, key "web"). */
  settings: WebAppSettings
  /** Route hashes to restore via the Back control, pushed by right-pane
   * navigation (tag occurrences, linked docs). */
  returnStack: string[]
}

export interface AppStore {
  state: AppState
  client: NoteGraphQLClient
  notes(): Note[]
  notebook(): Notebook | undefined
  conversationId(): string | undefined
  openNote(noteId: string, notebookId?: string): void
  openNotebook(notebookId: string): void
  /** The tag whose detail pane is open (`?tag=` on the route). */
  tagPaneTagId(): string | undefined
  /** Opens the right pane in tag mode for the tag. */
  openTagPane(tagId: string): void
  closeTagPane(): void
  /** Right-pane navigation that remembers where the reader was: pushes the
   * current route onto the return stack before jumping. */
  openNoteWithReturn(noteId: string, notebookId?: string): void
  openNotebookWithReturn(notebookId: string): void
  /** Pops the return stack, restoring the previous reader route. */
  goBack(): void
  openReader(): void
  openHome(): void
  /** Navigates to the search results screen. Scope "notebook" pins the query
   * to the currently open notebook. */
  openSearch(query: string, scope: SearchScope, method: SearchMethod): void
  openConfig(): void
  /** Applies immediately and persists to the store's sqlite (debounced). */
  updateSettings(partial: Partial<WebAppSettings>): void
  setPaneWidth(side: 'left' | 'right', width: number): void
  resetPaneWidths(): void
  openConversation(conversationId?: string): void
  toggleFolder(tagId: string): void
  toggleNotebook(notebookId: string): void
  setLeftTab(tab: LeftTab): void
  setRightTab(tab: RightTab): void
  toggleLeftPane(): void
  toggleRightPane(): void
  setActiveHeading(id: string): void
  setSearchOpen(open: boolean): void
  setMessage(message: string): void
  refreshCatalog(): Promise<void>
  refreshNote(): Promise<void>
  loadNotes(notebookId: string): Promise<void>
  loadMoreNotes(notebookId: string): Promise<void>
  /** Clears the note selection but keeps the notebook open (its notes stay in
   * the reader; the right pane falls back to notebook aggregates). */
  deselectNote(): void
}

export interface AppStoreOptions {
  client?: NoteGraphQLClient
  router?: RouterEnvironment
  paneStorage?: PaneStateStorage
}

const AppStoreContext = createContext<AppStore>()

export function AppStoreProvider(props: { children: JSX.Element; options?: AppStoreOptions }): JSX.Element {
  const store = createAppStore(props.options)
  return <AppStoreContext.Provider value={store}>{props.children}</AppStoreContext.Provider>
}

export function useApp(): AppStore {
  const store = useContext(AppStoreContext)
  if (!store) throw new Error('useApp was called outside the app store provider')
  return store
}

export function createAppStore(options: AppStoreOptions = {}): AppStore {
  const client = options.client ?? new NoteGraphQLClient('cli-serve')
  const router = options.router ?? browserRouterEnvironment()
  const paneStorage = options.paneStorage ?? browserPaneStorage()
  const [state, setState] = createStore<AppState>({
    route: parseRoute(router.currentHash()),
    loading: true,
    error: '',
    message: '',
    live: true,
    tags: [],
    tagClasses: [],
    notebooks: [],
    notesByNotebook: {},
    noteLoading: false,
    expandedFolders: [],
    expandedNotebooks: [],
    activeHeadingId: '',
    pane: readPaneState(paneStorage),
    notebookRevisions: {},
    catalogRevision: 0,
    searchOpen: false,
    settings: defaultWebSettings,
    returnStack: [],
  })

  let catalogGeneration = 0
  let noteGeneration = 0
  let catalogTimer: ReturnType<typeof setTimeout> | undefined
  let settingsTimer: ReturnType<typeof setTimeout> | undefined

  const loadSettings = async (): Promise<void> => {
    try {
      setState('settings', parseWebSettings(await client.appSetting(webSettingsKey)))
    } catch {
      // No stored settings (or an offline host) keeps the defaults.
    }
  }

  /** Optimistic: the new value applies immediately; the sqlite write is
   * debounced so a slider drag is one persisted document, not dozens. */
  const updateSettings = (partial: Partial<WebAppSettings>) => {
    const next: WebAppSettings = {
      ...state.settings,
      ...partial,
      ...(partial.fontScale !== undefined ? { fontScale: clampFontScale(partial.fontScale) } : {}),
    }
    setState('settings', next)
    if (settingsTimer) clearTimeout(settingsTimer)
    settingsTimer = setTimeout(() => {
      settingsTimer = undefined
      void client.setAppSetting(webSettingsKey, serializeWebSettings(state.settings))
        .catch((error: unknown) => {
          setState('message', `Could not save the settings: ${errorMessage(error)}`)
        })
    }, 500)
  }

  const setPane = (next: PaneState) => {
    setState('pane', next)
    writePaneState(next, paneStorage)
  }

  const bumpNotebook = (notebookId: string) => {
    setState('notebookRevisions', notebookId, (revision) => (revision ?? 0) + 1)
  }

  /** Reloads a notebook's notes, keeping as many pages as are already on
   * screen so an events-feed refresh never truncates a lazily grown list. */
  const loadNotes = async (notebookId: string): Promise<void> => {
    const target = state.notesByNotebook[notebookId]?.length ?? 0
    const pages = Math.max(1, Math.ceil(target / notebookPageLimit))
    try {
      let all: Note[] = []
      for (let page = 0; page < pages; page += 1) {
        const chunk = await client.notes(notebookId, page * notebookPageLimit)
        all = all.concat(chunk)
        if (chunk.length < notebookPageLimit) break
      }
      setState('notesByNotebook', notebookId, all)
    } catch (error) {
      setState('message', `Could not load notes: ${errorMessage(error)}`)
    }
  }

  /** Appends the next page of notes for the reader's lazy scroll. Does nothing
   * once the last fetched page came back short (the list is complete). */
  const loadMoreNotes = async (notebookId: string): Promise<void> => {
    const current = state.notesByNotebook[notebookId]
    if (!current || current.length === 0 || current.length % notebookPageLimit !== 0) return
    try {
      const chunk = await client.notes(notebookId, current.length)
      if (chunk.length > 0) setState('notesByNotebook', notebookId, [...current, ...chunk])
    } catch (error) {
      setState('message', `Could not load more notes: ${errorMessage(error)}`)
    }
  }

  const refreshCatalog = async (): Promise<void> => {
    const generation = ++catalogGeneration
    setState({ loading: true, error: '' })
    try {
      const [tags, tagClasses] = await Promise.all([client.tags(), client.tagClasses()])
      if (generation !== catalogGeneration) return
      setState({ tags, tagClasses })
      const notebooks = await loadNotebookPages(
        client,
        'updatedAtDesc',
        [],
        () => generation === catalogGeneration,
        (values) => {
          if (generation === catalogGeneration) setState('notebooks', values)
        },
      )
      if (!notebooks || generation !== catalogGeneration) return
      setState('notebooks', notebooks)
      setState('catalogRevision', (revision) => revision + 1)
    } catch (error) {
      if (generation !== catalogGeneration) return
      setState('error', errorMessage(error))
    } finally {
      if (generation === catalogGeneration) setState('loading', false)
    }
  }

  /** Resolves the routed selection: a note route fetches the note (which names
   * its notebook), a notebook route opens its first note. */
  const applySelection = async (route: Route): Promise<void> => {
    const generation = ++noteGeneration
    if (route.kind === 'note') {
      setState({ noteId: route.noteId, noteLoading: true, activeHeadingId: '' })
      try {
        const note = await client.note(route.noteId)
        if (generation !== noteGeneration) return
        setState({ note, notebookId: note.notebookId })
        if (!state.notesByNotebook[note.notebookId]) await loadNotes(note.notebookId)
        setState('expandedNotebooks', (current) =>
          current.includes(note.notebookId) ? current : [...current, note.notebookId])
      } catch (error) {
        if (generation !== noteGeneration) return
        setState({ note: undefined, message: `Could not open that note: ${errorMessage(error)}` })
      } finally {
        if (generation === noteGeneration) setState('noteLoading', false)
      }
      return
    }
    if (route.kind === 'notebook') {
      // No auto-selection: the reader shows the notebook's notes as one
      // continuous scroll, and the right pane shows notebook-level aggregates
      // until the user clicks a note.
      setState({ notebookId: route.notebookId, noteId: undefined, note: undefined, activeHeadingId: '' })
      setState('expandedNotebooks', (current) =>
        current.includes(route.notebookId) ? current : [...current, route.notebookId])
      await loadNotes(route.notebookId)
      return
    }
    // The search and config screens keep the current selection so "this
    // notebook" scope and the Reader button still refer to what was open.
    if (route.kind === 'search' || route.kind === 'config') return
    setState({ notebookId: undefined, noteId: undefined, note: undefined, activeHeadingId: '' })
  }

  const refreshNote = async (): Promise<void> => {
    const noteId = state.noteId
    if (!noteId) return
    const generation = ++noteGeneration
    try {
      const note = await client.note(noteId)
      if (generation !== noteGeneration) return
      setState('note', note)
    } catch (error) {
      if (generation === noteGeneration) setState('message', `Could not refresh the note: ${errorMessage(error)}`)
    }
  }

  const go = (route: Route) => navigate(router, route)
  const openNote = (noteId: string, notebookId?: string) => {
    if (notebookId) {
      setState('expandedNotebooks', (current) =>
        current.includes(notebookId) ? current : [...current, notebookId])
    }
    go({ kind: 'note', noteId, ...(conversationId() ? { conversationId: conversationId() } : {}) })
  }
  const conversationId = () =>
    state.route.kind === 'note' || state.route.kind === 'notebook' ? state.route.conversationId : undefined
  const tagPaneTagId = () => routeTagId(state.route)

  /** Pushes the current location, then navigates keeping the tag pane open so
   * a jump from the pane does not close what drove it. */
  const goWithReturn = (route: Route) => {
    setState('returnStack', (stack) => pushReturn(stack, formatRoute(state.route)))
    const tagId = tagPaneTagId()
    go(tagId ? withTag(route, tagId) : route)
  }

  const scheduleCatalogRefresh = () => {
    if (catalogTimer) return
    catalogTimer = setTimeout(() => {
      catalogTimer = undefined
      void refreshCatalog()
    }, 400)
  }

  let appliedSelection = ''
  let readerRoute = rememberReaderRoute(state.route)
  const unsubscribeRoute = subscribeRoute(router, (route) => {
    readerRoute = rememberReaderRoute(route, readerRoute)
    setState('route', route)
    const key = selectionKey(route)
    if (key === appliedSelection) return
    appliedSelection = key
    void applySelection(route)
  })

  void (async () => {
    try {
      await client.initialize()
    } catch (error) {
      // Registration failure is reported but never blocks a host that serves
      // notes without authentication.
      setState('message', `Client registration failed: ${errorMessage(error)}`)
    }
    void loadSettings()
    await refreshCatalog()
  })()

  let firstConnect = true
  const unsubscribeEvents = subscribeNoteEvents({
    headers: () => client.streamHeaders(),
    onEvent: (event) => {
      if (event.notebookId) {
        bumpNotebook(event.notebookId)
        // Any notebook whose notes are on screen — the open one, or another the
        // tree has expanded — is re-read; the open note itself is re-read too so
        // an edit from another client lands in the reader.
        if (state.notesByNotebook[event.notebookId]) void loadNotes(event.notebookId)
        if (event.notebookId === state.notebookId) void refreshNote()
      }
      // Note events carry their own targeted refetch above; anything else can
      // move a notebook between folders or columns, so the catalog reloads.
      if (event.kind !== 'note-created' && event.kind !== 'note-updated') scheduleCatalogRefresh()
    },
    onConnect: () => {
      setState('live', true)
      if (firstConnect) { firstConnect = false; return }
      scheduleCatalogRefresh()
    },
    onUnavailable: () => setState('live', false),
  })

  onCleanup(() => {
    unsubscribeRoute()
    unsubscribeEvents()
    if (catalogTimer) clearTimeout(catalogTimer)
    if (settingsTimer) clearTimeout(settingsTimer)
  })

  const store: AppStore = {
    state,
    client,
    notes: () => (state.notebookId ? state.notesByNotebook[state.notebookId] ?? [] : []),
    notebook: () => state.notebooks.find((notebook) => notebook.notebookId === state.notebookId),
    conversationId,
    openNote,
    openNotebook: (notebookId) => go({ kind: 'notebook', notebookId }),
    tagPaneTagId,
    openTagPane: (tagId) => {
      // The pane must be visible for the selection to mean anything.
      if (!state.pane.rightOpen) setPane({ ...state.pane, rightOpen: true })
      if (state.route.kind === 'note' || state.route.kind === 'notebook') {
        go(withTag(state.route, tagId))
        return
      }
      // No reader selection on the route (home): fall back to the open
      // notebook so the pane still has a place to live.
      if (state.notebookId) go({ kind: 'notebook', notebookId: state.notebookId, tagId })
    },
    closeTagPane: () => go(withTag(state.route, undefined)),
    openNoteWithReturn: (noteId, notebookId) => {
      if (notebookId) {
        setState('expandedNotebooks', (current) =>
          current.includes(notebookId) ? current : [...current, notebookId])
      }
      goWithReturn({ kind: 'note', noteId })
    },
    openNotebookWithReturn: (notebookId) => goWithReturn({ kind: 'notebook', notebookId }),
    goBack: () => {
      const popped = popReturn(state.returnStack)
      setState('returnStack', popped.stack)
      if (popped.hash) navigate(router, parseRoute(popped.hash))
    },
    openReader: () => go(readerRoute),
    openHome: () => go({ kind: 'home' }),
    openSearch: (query, scope, method) => {
      const notebookId = scope === 'notebook' ? state.notebookId : undefined
      go({
        kind: 'search',
        query,
        scope: notebookId ? scope : 'all',
        method,
        ...(notebookId ? { notebookId } : {}),
      })
    },
    openConfig: () => go({ kind: 'config' }),
    updateSettings,
    setPaneWidth: (side, width) => {
      const clamped = clampPaneWidth(side, width)
      setPane(side === 'left'
        ? { ...state.pane, leftWidth: clamped }
        : { ...state.pane, rightWidth: clamped })
    },
    resetPaneWidths: () => {
      const next = { ...state.pane }
      delete next.leftWidth
      delete next.rightWidth
      setPane(next)
    },
    openConversation: (nextConversationId) => go(withConversation(state.route, nextConversationId)),
    toggleFolder: (tagId) => setState('expandedFolders', (current) => toggle(current, tagId)),
    toggleNotebook: (notebookId) => {
      setState('expandedNotebooks', (current) => toggle(current, notebookId))
      if (!state.notesByNotebook[notebookId]) void loadNotes(notebookId)
    },
    setLeftTab: (tab) => setPane(withLeftTab(state.pane, tab)),
    setRightTab: (tab) => setPane(withRightTab(state.pane, tab)),
    toggleLeftPane: () => setPane({ ...state.pane, leftOpen: !state.pane.leftOpen }),
    toggleRightPane: () => setPane({ ...state.pane, rightOpen: !state.pane.rightOpen }),
    setActiveHeading: (id) => setState('activeHeadingId', id),
    setSearchOpen: (open) => setState('searchOpen', open),
    setMessage: (message) => setState('message', message),
    refreshCatalog: async () => {
      await refreshCatalog()
      setState(produce((draft) => { draft.notesByNotebook = {} }))
      if (state.notebookId) await loadNotes(state.notebookId)
      await refreshNote()
    },
    refreshNote,
    loadNotes,
    loadMoreNotes,
    deselectNote: () => {
      const notebookId = state.notebookId
      if (notebookId) go({ kind: 'notebook', notebookId })
      else go({ kind: 'home' })
    },
  }
  return store
}

export function routeHref(route: Route): string {
  return formatRoute(route)
}

function selectionKey(route: Route): string {
  switch (route.kind) {
    case 'note': return `note:${route.noteId}`
    case 'notebook': return `notebook:${route.notebookId}`
    case 'search': return `search:${route.method}:${route.scope}:${route.query}`
    default: return 'home'
  }
}

function toggle(values: string[], value: string): string[] {
  return values.includes(value) ? values.filter((entry) => entry !== value) : [...values, value]
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
