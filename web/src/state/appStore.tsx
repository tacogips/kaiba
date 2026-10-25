import { notebookId as asNotebookId } from '../notes/ids'
import { createContext, createSignal, getOwner, onCleanup, runWithOwner, useContext, type JSX, type Accessor, type Setter } from 'solid-js'
import { notebookSource } from '../notes/notebookSource'
import { createStore, reconcile } from 'solid-js/store'
import { createWritingDrafts } from './writingDrafts'
import { createSettingsSave } from './settingsSave'
import type { DocumentViewSelection } from '../notes/documentVersions'
import { createOCRTasks } from './ocrTasks'
import { createNotebookAutosave } from './notebookAutosave'
import { NoteGraphQLClient, NoteTransportError, notebookPageLimit } from '../notes/client'
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
import { browserReaderRouteStorage, readReaderRoute, writeReaderRoute } from './readerRouteStorage'
import {
  browserPaneStorage,
  clampPaneWidth,
  readPaneState,
  withCenterTab,
  withLeftTab,
  withRightTab,
  writePaneState,
  type CenterTab,
  type LeftTab,
  type NotebookView,
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
import { NotebookReadOnlyController } from '../notes/controller'
import type { NoteId, NotebookId, TagId } from '../notes/ids'

// The single owner of selection, pane layout, the note catalog and the note
// events subscription. Panes read from here instead of receiving props drilled
// down from a view, and every live update enters through one feed.

/** Whether the note API accepts this client. "unknown" until the first call
 * lands, so the shell renders neither the reader nor a login form on a host
 * whose auth mode has not been observed yet. */
export type AuthState = 'unknown' | 'authenticated' | 'unauthenticated'

export interface NotebookWriterSession {
  draft: ReturnType<ReturnType<typeof createWritingDrafts>['get']>
  autosave: ReturnType<typeof createNotebookAutosave>
  currentNote: Accessor<number>
  setCurrentNote: Setter<number>
}

export interface AppState {
  route: Route
  loading: boolean
  auth: AuthState
  error: string
  message: string
  messageSeverity: 'info' | 'error'
  /** False only once the events feed has reported itself unavailable; the first
   * long poll on a quiet store can stay open for its whole timeout, which is
   * not an outage. */
  live: boolean
  tags: NoteTag[]
  tagClasses: NoteTagClass[]
  notebooks: Notebook[]
  notesByNotebook: Record<string, Note[]>
  notebookId?: NotebookId
  noteId?: NoteId
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
  /** Whether the configured server can serve engine-backed search. */
  searchEngineEnabled: boolean
  /** App settings from the store's sqlite (`app_settings`, key "web"). */
  settings: WebAppSettings
  /** Up to 500 prior reader selections and explicit tag/link return routes.
   * Restoring an entry does not add the route being left. */
  returnStack: string[]
}

export interface AppStore {
  settingsSave: ReturnType<typeof createSettingsSave>
  writingDrafts: ReturnType<typeof createWritingDrafts>
  notebookAutosave: ReturnType<typeof createNotebookAutosave>
  notebookWriter(notebookId: NotebookId): Promise<NotebookWriterSession>
  notebookWritingContext(): { source: string; noteNumber: number } | undefined
  ocrTasks: ReturnType<typeof createOCRTasks>
  documentViews: Map<NotebookId, DocumentViewSelection>
  state: AppState
  client: NoteGraphQLClient
  notes(): Note[]
  notebook(): Notebook | undefined
  conversationId(): string | undefined
  openNote(noteId: NoteId, notebookId?: NotebookId): void
  openNotebook(notebookId: NotebookId): void
  /** The tag whose detail pane is open (`?tag=` on the route). */
  tagPaneTagId(): string | undefined
  /** Opens the right pane in tag mode for the tag. */
  openTagPane(tagId: TagId): void
  /** Entity-page navigation between tags (a co-occurring chip): remembers the
   * current location first, so Back walks back through the tags visited. */
  openTagPaneWithReturn(tagId: TagId): void
  closeTagPane(): void
  /** Right-pane navigation that remembers where the reader was: pushes the
   * current route onto the return stack before jumping. */
  openNoteWithReturn(noteId: NoteId, notebookId?: NotebookId): void
  openNotebookWithReturn(notebookId: NotebookId): void
  /** Pops the return stack, restoring the previous reader route. */
  goBack(): void
  openReader(): void
  openHome(): void
  openFastNotes(query?: string, layout?: 'list' | 'cards'): void
  openFastNote(noteId: NoteId): void
  /** Navigates to the search results screen. Scope "notebook" pins the query
   * to the currently open notebook. */
  openSearch(query: string, scope: SearchScope, method: SearchMethod): void
  openConfig(): void
  openTasks(): void
  /** Applies immediately and persists to the store's sqlite (debounced). */
  updateSettings(partial: Partial<WebAppSettings>): void
  setPaneWidth(side: 'left' | 'right', width: number): void
  resetPaneWidths(): void
  openConversation(conversationId?: NotebookId): void
  toggleFolder(tagId: TagId): void
  toggleNotebook(notebookId: NotebookId): void
  setLeftTab(tab: LeftTab): void
  setCenterTab(tab: CenterTab): void
  setRightTab(tab: RightTab): void
  setNotebookView(view: NotebookView): void
  toggleLeftPane(): void
  toggleRightPane(): void
  setActiveHeading(id: string): void
  setSearchOpen(open: boolean): void
  setSearchEngineEnabled(enabled: boolean): void
  reloadSearchEngineCapability(): Promise<void>
  setMessage(message: string, severity?: 'info' | 'error'): void
  dismissError(): void
  refreshCatalog(): Promise<void>
  /** Adopts an API key pasted into the login view and reloads the catalog.
   * Rejects when the key is refused, so the login view can stay put and say
   * so. */
  signInWithKey(key: string): Promise<void>
  refreshNote(): Promise<void>
  loadNotes(notebookId: NotebookId): Promise<void>
  loadMoreNotes(notebookId: NotebookId): Promise<void>
  canLoadMoreNotes(notebookId: NotebookId): boolean
  notesLoadState(notebookId: NotebookId): 'idle' | 'loading' | 'ready' | 'error'
  /** Changes the open or named notebook's persisted access mode. */
  setNotebookReadOnly(notebookId: NotebookId, readOnly: boolean): Promise<void>
  /** Clears the note selection but keeps the notebook open (its notes stay in
   * the reader; the right pane falls back to notebook aggregates). */
  deselectNote(): void
}

export interface AppStoreOptions {
  client?: NoteGraphQLClient
  router?: RouterEnvironment
  paneStorage?: PaneStateStorage
  readerRouteStorage?: PaneStateStorage
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
  const owner = getOwner()
  const notebookWriters = new Map<NotebookId, NotebookWriterSession>()
  const writingDrafts = createWritingDrafts()
  const documentViews = new Map<NotebookId, DocumentViewSelection>()
  const client = options.client ?? new NoteGraphQLClient()
  const router = options.router ?? browserRouterEnvironment()
  const paneStorage = options.paneStorage ?? browserPaneStorage()
  const readerStorage = options.readerRouteStorage ?? (options.router ? undefined : browserReaderRouteStorage())
  const [state, setState] = createStore<AppState>({
    route: { ...parseRoute(router.currentHash()) },
    loading: true,
    auth: 'unknown',
    error: '',
    message: '',
    messageSeverity: 'info',
    live: true,
    tags: [],
    tagClasses: [],
    notebooks: [],
    notesByNotebook: {},
    noteLoading: false,
    expandedFolders: [],
    expandedNotebooks: [],
    activeHeadingId: '',
    pane: { ...readPaneState(paneStorage) },
    notebookRevisions: {},
    catalogRevision: 0,
    searchOpen: false,
    searchEngineEnabled: false,
    settings: { ...defaultWebSettings },
    returnStack: [],
  })

  const setMessage = (message: string, severity: 'info' | 'error' = 'info') => setState({ message, messageSeverity: severity })
  const settingsSave = createSettingsSave((snapshot) => client.setAppSetting(webSettingsKey, snapshot),
    (error) => setMessage(`Could not save the settings: ${errorMessage(error)}`, 'error'))

  let catalogGeneration = 0
  let noteGeneration = 0
  let catalogTimer: ReturnType<typeof setTimeout> | undefined
  const readOnlyController = new NotebookReadOnlyController({
    setReadOnly: (notebookId, readOnly) => client.setNotebookReadOnly(notebookId, readOnly),
  }, (updated, error) => {
    setState('notebooks', (notebooks) => notebooks.map((notebook) =>
      notebook.notebookId === updated.notebookId ? updated : notebook))
    if (error) setMessage(`Could not change notebook access: ${error}`, 'error')
  })

  /** A 401 is not a failure to report in the error banner: it is a state the
   * shell renders a login view for. The client has already discarded the
   * rejected credential by the time this runs. */
  const adoptUnauthenticated = (error: unknown): boolean => {
    if (!isUnauthorized(error)) return false
    settingsSave.reset()
    notebookAutosave.clear()
    for (const writer of notebookWriters.values()) writer.autosave.clear()
    notebookWriters.clear()
    ocrTasks.clear()
    documentViews.clear()
    writingDrafts.clear()
    readerRoute = { kind: 'home' }
    writeReaderRoute(readerRoute, readerStorage)
    setState({ auth: 'unauthenticated', error: '', message: '', loading: false })
    return true
  }

  const loadSettings = async (): Promise<void> => {
    const revision = settingsSave.revision()
    try {
      const settings = parseWebSettings(await client.appSetting(webSettingsKey))
      if (settingsSave.revision() === revision && settingsSave.status() === 'idle') setState('settings', settings)
    } catch {
      // No stored settings (or an offline host) keeps the defaults.
    }
  }

  const loadSearchEngineCapability = async (): Promise<void> => {
    try {
      setState('searchEngineEnabled', await client.searchEngineCapability())
    } catch {
      setState('searchEngineEnabled', false)
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
    settingsSave.queue(serializeWebSettings(next))
  }

  const setPane = (next: PaneState) => {
    setState('pane', next)
    writePaneState(next, paneStorage)
  }

  const bumpNotebook = (notebookId: NotebookId) => {
    setState('notebookRevisions', notebookId, (revision) => (revision ?? 0) + 1)
  }

  // Overlapping loads for one notebook race: without a generation guard an
  // older reload finishing late replaces pages a newer load (or a lazy-scroll
  // append) already put on screen.
  const noteLoadGenerations: Record<string, number> = {}
  const [notePagesComplete, setNotePagesComplete] = createStore<Record<string, boolean>>({})
  const [noteLoadStates, setNoteLoadStates] = createStore<Record<string, 'idle' | 'loading' | 'ready' | 'error'>>({})
  const notePageRequests = new Map<NotebookId, Promise<void>>()
  const canLoadMoreNotes = (notebookId: NotebookId) => {
    const count = state.notesByNotebook[notebookId]?.length ?? 0
    const total = state.notebooks.find((book) => book.notebookId === notebookId)?.noteCount
    return count > 0 && !notePagesComplete[notebookId] && (total == null || count < total)
  }
  const nextNoteLoadGeneration = (notebookId: NotebookId): number => {
    const generation = (noteLoadGenerations[notebookId] ?? 0) + 1
    noteLoadGenerations[notebookId] = generation
    return generation
  }

  /** Reloads a notebook's notes, keeping as many pages as are already on
   * screen so an events-feed refresh never truncates a lazily grown list. */
  const loadNotes = async (notebookId: NotebookId): Promise<void> => {
    const generation = nextNoteLoadGeneration(notebookId)
    setNoteLoadStates(notebookId, 'loading')
    const target = state.notesByNotebook[notebookId]?.length ?? 0
    const pages = Math.max(1, Math.ceil(target / notebookPageLimit))
    try {
      let all: Note[] = []
      for (let page = 0; page < pages; page += 1) {
        const chunk = await client.notes(notebookId, page * notebookPageLimit)
        all = all.concat(chunk)
        if (chunk.length < notebookPageLimit) break
      }
      if (noteLoadGenerations[notebookId] !== generation) return
      setNotePagesComplete(notebookId, all.length % notebookPageLimit !== 0 || all.length === 0)
      setState('notesByNotebook', notebookId, reconcile(all, { key: 'noteId' }))
      setNoteLoadStates(notebookId, 'ready')
    } catch (error) {
      if (noteLoadGenerations[notebookId] !== generation) return
      setNoteLoadStates(notebookId, 'error')
      if (adoptUnauthenticated(error)) return
      setMessage(`Could not load notes: ${errorMessage(error)}`, 'error')
    }
  }

  /** Appends the next page of notes for the reader's lazy scroll. Does nothing
   * once the last fetched page came back short (the list is complete). */
  const loadMoreNotes = (notebookId: NotebookId): Promise<void> => {
    const pending = notePageRequests.get(notebookId)
    if (pending) return pending
    const current = state.notesByNotebook[notebookId]
    if (!current || !canLoadMoreNotes(notebookId)) return Promise.resolve()
    const generation = nextNoteLoadGeneration(notebookId)
    const request = (async () => {
      try {
        const chunk = await client.notes(notebookId, current.length)
        if (noteLoadGenerations[notebookId] !== generation) return
        setNotePagesComplete(notebookId, chunk.length < notebookPageLimit)
        if (chunk.length > 0) setState('notesByNotebook', notebookId, reconcile([...current, ...chunk], { key: 'noteId' }))
      } catch (error) {
        if (adoptUnauthenticated(error)) return
        setMessage(`Could not load more notes: ${errorMessage(error)}`, 'error')
      }
    })().finally(() => { notePageRequests.delete(notebookId) })
    notePageRequests.set(notebookId, request)
    return request
  }

  const refreshCatalog = async (): Promise<void> => {
    const generation = ++catalogGeneration
    const readOnlySnapshot = readOnlyController.snapshot()
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
          if (generation === catalogGeneration) {
            setState('notebooks', reconcile(values.map((notebook) =>
              readOnlyController.adopt(notebook, readOnlySnapshot)), { key: 'notebookId' }))
          }
        },
      )
      if (!notebooks || generation !== catalogGeneration) return
      setState('notebooks', reconcile(notebooks.map((notebook) =>
        readOnlyController.adopt(notebook, readOnlySnapshot)), { key: 'notebookId' }))
      setState('catalogRevision', (revision) => revision + 1)
      setState('auth', 'authenticated')
    } catch (error) {
      if (generation !== catalogGeneration) return
      if (adoptUnauthenticated(error)) return
      setState('error', errorMessage(error))
    } finally {
      if (generation === catalogGeneration) setState('loading', false)
    }
  }

  /** Resolves the routed selection: a note route fetches the note (which names
   * its notebook), a notebook route opens its first note. */
  const applySelection = async (route: Route): Promise<void> => {
    const generation = ++noteGeneration
    if (route.kind === 'note' || (route.kind === 'fast' && route.noteId)) {
      const noteId = route.noteId!
      setState({ noteId, noteLoading: true, activeHeadingId: '' })
      try {
        const note = await client.note(noteId)
        if (generation !== noteGeneration) return
        setState({ note, notebookId: note.notebookId })
        if (route.kind === 'fast') {
          if (!state.notebooks.some((book) => book.notebookId === note.notebookId)) {
            const notebook = await client.notebook(note.notebookId)
            if (generation !== noteGeneration) return
            setState('notebooks', (books) => [...books.filter((book) => book.notebookId !== notebook.notebookId), notebook])
          }
        } else {
          if (!state.notesByNotebook[note.notebookId]) await loadNotes(note.notebookId)
          while (generation === noteGeneration && !state.notesByNotebook[note.notebookId]?.some((row) => row.noteId === note.noteId)) {
            const before = state.notesByNotebook[note.notebookId]?.length ?? 0
            await loadMoreNotes(note.notebookId)
            if ((state.notesByNotebook[note.notebookId]?.length ?? 0) <= before) break
          }
        }
        if (generation !== noteGeneration) return
        setState('expandedNotebooks', (current) =>
          current.includes(note.notebookId) ? current : [...current, note.notebookId])
      } catch (error) {
        if (generation !== noteGeneration) return
        if (adoptUnauthenticated(error)) return
        setState({ note: undefined, message: `Could not open that note: ${errorMessage(error)}`, messageSeverity: 'error' })
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
      if (!state.notebooks.some((notebook) => notebook.notebookId === route.notebookId)) {
        try {
          const notebook = await client.notebook(route.notebookId)
          if (generation !== noteGeneration) return
          setState('notebooks', (current) => [...current.filter((item) => item.notebookId !== notebook.notebookId), notebook])
        } catch (error) {
          if (generation !== noteGeneration) return
          if (adoptUnauthenticated(error)) return
          setMessage(`Could not load notebook details: ${errorMessage(error)}`, 'error')
        }
      }
      await loadNotes(route.notebookId)
      return
    }
    // The search and config screens keep the current selection so "this
    // notebook" scope and the Reader button still refer to what was open.
    if (route.kind === 'search' || route.kind === 'config' || route.kind === 'tasks') return
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
      if (generation !== noteGeneration) return
      if (adoptUnauthenticated(error)) return
      setMessage(`Could not refresh the note: ${errorMessage(error)}`, 'error')
    }
  }

  const go = (route: Route) => navigate(router, route)
  const openNote = (noteId: NoteId, notebookId?: NotebookId) => {
    setPane(withCenterTab(state.pane, 'notebook'))
    if (notebookId) {
      setState('expandedNotebooks', (current) =>
        current.includes(notebookId) ? current : [...current, notebookId])
    }
    go({ kind: 'note', noteId, ...(conversationId() ? { conversationId: conversationId() } : {}) })
  }
  const conversationId = () =>
    state.route.kind === 'note' || state.route.kind === 'notebook' || state.route.kind === 'fast' ? state.route.conversationId : undefined
  const tagPaneTagId = () => routeTagId(state.route)

  const openTagPaneRoute = (tagId: TagId) => {
    // The pane must be visible for the selection to mean anything.
    if (!state.pane.rightOpen) setPane({ ...state.pane, rightOpen: true })
    if (state.route.kind === 'note' || state.route.kind === 'notebook' || state.route.kind === 'fast') {
      go(withTag(state.route, tagId))
      return
    }
    // No reader selection on the route (home): fall back to the open
    // notebook so the pane still has a place to live.
    if (state.notebookId) go({ kind: 'notebook', notebookId: state.notebookId, tagId })
  }

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
  let previousSourceRoute: Route | undefined = state.route.kind === 'note' || state.route.kind === 'notebook' || (state.route.kind === 'fast' && Boolean(state.route.noteId))
    ? { ...state.route } : undefined
  let restoringHash: string | undefined
  let readerRoute = rememberReaderRoute(state.route, readReaderRoute(readerStorage))
  const unsubscribeRoute = subscribeRoute(router, (route) => {
    // Observe the central route boundary so tree clicks, PDF paging, search
    // results, linked notes, and direct hash changes all share one history.
    const restoring = restoringHash === formatRoute(route)
    restoringHash = undefined
    if (route.kind === 'note' || route.kind === 'notebook' || route.kind === 'home' || route.kind === 'fast') {
      if (previousSourceRoute && selectionKey(previousSourceRoute) !== selectionKey(route) && !restoring) {
        setState('returnStack', (stack) => pushReturn(stack, formatRoute(previousSourceRoute!)))
      }
      previousSourceRoute = route.kind === 'home' || (route.kind === 'fast' && !route.noteId) ? undefined : { ...route }
    }
    if (route.kind === 'tasks') previousSourceRoute = undefined
    readerRoute = rememberReaderRoute(route, readerRoute)
    writeReaderRoute(readerRoute, readerStorage)
    // Routes are a union: fields from the previous variant must be removed.
    setState('route', reconcile({ ...route }))
    const key = selectionKey(route)
    if (key === appliedSelection) return
    appliedSelection = key
    if (route.kind === 'fast' && route.noteId && !state.pane.rightOpen) setPane({ ...state.pane, rightOpen: true })
    if (route.kind === 'note' || route.kind === 'notebook') {
      setPane(withCenterTab(state.pane, 'notebook'))
    } else if (route.kind === 'home') {
      setPane(withCenterTab(state.pane, 'list'))
    }
    void applySelection(route)
  })

  void (async () => {
    try {
      await client.initialize()
    } catch (error) {
      // Registration failure is reported but never blocks a host that serves
      // notes without authentication.
      setMessage(`Client registration failed: ${errorMessage(error)}`, 'error')
    }
    void loadSettings()
    void loadSearchEngineCapability()
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
      if (state.route.kind === 'fast' || (event.kind !== 'note-created' && event.kind !== 'note-updated')) scheduleCatalogRefresh()
    },
    onConnect: () => {
      setState('live', true)
      if (firstConnect) { firstConnect = false; return }
      void loadSearchEngineCapability()
      scheduleCatalogRefresh()
    },
    onUnavailable: () => setState('live', false),
  })

  onCleanup(() => {
    unsubscribeRoute()
    unsubscribeEvents()
    if (catalogTimer) clearTimeout(catalogTimer)
  })

  const ocrTasks = createOCRTasks(client, (note) => {
    if (state.noteId === note.noteId) setState('note', note)
    bumpNotebook(note.notebookId)
    if (state.notesByNotebook[note.notebookId]) void loadNotes(note.notebookId)
  }, (error, task) => {
    if (!adoptUnauthenticated(error)) setMessage(`${task.label} · Page ${task.pageNumber ?? '?'} OCR failed: ${errorMessage(error)}. Open Tasks to retry.`, 'error')
  })

  const notebookAutosave = createNotebookAutosave(client, writingDrafts.get('new-notebook-body'), async () => {
    await refreshCatalog()
    const saved = notebookAutosave.notebook()
    if (saved && state.route.kind === 'home') store.openNotebook(saved.notebookId)
  }, () => store.openHome())

  const store: AppStore = {
    writingDrafts,
    notebookAutosave,
    notebookWriter: async (notebookId) => {
      const cached = notebookWriters.get(notebookId)
      if (cached) return cached
      if (!state.notesByNotebook[notebookId]) await loadNotes(notebookId)
      if (!state.notesByNotebook[notebookId]) throw new Error('Could not load the notebook. Retry before editing.')
      while (canLoadMoreNotes(notebookId)) {
        const before = state.notesByNotebook[notebookId]?.length ?? 0
        await loadMoreNotes(notebookId)
        if ((state.notesByNotebook[notebookId]?.length ?? 0) <= before) throw new Error('Could not load the complete notebook. Retry before editing.')
      }
      const book = state.notebooks.find((item) => item.notebookId === notebookId)
      const notes = state.notesByNotebook[notebookId] ?? []
      if (!book || book.readOnly || notes.some((note) => note.readOnly)) throw new Error('This notebook contains read-only notes.')
      const draft = writingDrafts.get(`notebook:${notebookId}`)
      draft.setBaseText(notebookSource(notes.map((note) => note.bodyMarkdown)))
      draft.setText(notebookSource(notes.map((note) => {
        const previous = writingDrafts.get(`edit:${note.noteId}`)
        return previous.baseText() !== undefined && previous.text() !== previous.baseText() ? previous.text() : note.bodyMarkdown
      })))
      const autosave = runWithOwner(owner, () => createNotebookAutosave(client, draft, async () => {
        await refreshCatalog(); await loadNotes(notebookId)
      }, undefined, book))!
      const [currentNote, setCurrentNote] = createSignal(state.note?.notebookId === notebookId ? state.note.noteNumber : 1)
      const writer = { draft, autosave, currentNote, setCurrentNote }
      notebookWriters.set(notebookId, writer)
      for (const note of notes) {
        const previous = writingDrafts.get(`edit:${note.noteId}`)
        previous.setText(''); previous.setBaseText(undefined)
      }
      return writer
    },
    notebookWritingContext: () => {
      const writer = state.notebookId ? notebookWriters.get(state.notebookId) : undefined
      return writer ? { source: writer.draft.text(), noteNumber: writer.currentNote() } : undefined
    },
    ocrTasks,
    documentViews,
    state,
    client,
    notes: () => (state.notebookId ? state.notesByNotebook[state.notebookId] ?? [] : []),
    notebook: () => state.notebooks.find((notebook) => notebook.notebookId === state.notebookId),
    conversationId,
    openNote,
    openNotebook: (notebookId) => {
      setPane(withCenterTab(state.pane, 'notebook'))
      go({ kind: 'notebook', notebookId })
    },
    tagPaneTagId,
    openTagPane: openTagPaneRoute,
    openTagPaneWithReturn: (tagId) => {
      setState('returnStack', (stack) => pushReturn(stack, formatRoute(state.route)))
      openTagPaneRoute(tagId)
    },
    closeTagPane: () => go(withTag(state.route, undefined)),
    openNoteWithReturn: (noteId, notebookId) => {
      setPane(withCenterTab(state.pane, 'notebook'))
      if (notebookId) {
        setState('expandedNotebooks', (current) =>
          current.includes(notebookId) ? current : [...current, notebookId])
      }
      goWithReturn({ kind: 'note', noteId })
    },
    openNotebookWithReturn: (notebookId) => {
      setPane(withCenterTab(state.pane, 'notebook'))
      goWithReturn({ kind: 'notebook', notebookId })
    },
    goBack: () => {
      let popped = popReturn(state.returnStack)
      // Explicit no-move jumps may leave the current route on top. Skip them
      // so one press always moves to a different location when one exists.
      while (popped.hash === formatRoute(state.route)) popped = popReturn(popped.stack)
      setState('returnStack', popped.stack)
      if (popped.hash) {
        restoringHash = popped.hash
        navigate(router, parseRoute(popped.hash))
      }
    },
    openReader: () => go(readerRoute),
    openHome: () => {
      setPane(withCenterTab(state.pane, 'list'))
      go({ kind: 'home' })
    },
    openFastNotes: (query, layout) => {
      const previous = state.route.kind === 'fast' ? state.route : undefined
      go({ kind: 'fast', query: query ?? previous?.query ?? '', layout: layout ?? previous?.layout ?? 'list' })
    },
    openFastNote: (noteId) => {
      const previous = state.route.kind === 'fast' ? state.route : undefined
      if (!state.pane.rightOpen) setPane({ ...state.pane, rightOpen: true })
      go({ kind: 'fast', query: previous?.query ?? '', layout: previous?.layout ?? 'list', noteId })
    },
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
    openTasks: () => {
      if (state.route.kind !== 'tasks') goWithReturn({ kind: 'tasks' })
    },
    openConfig: () => go({ kind: 'config' }),
    updateSettings,
    settingsSave,
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
    setCenterTab: (tab) => setPane(withCenterTab(state.pane, tab)),
    setRightTab: (tab) => setPane(withRightTab(state.pane, tab)),
    setNotebookView: (notebookView) => setPane({ ...state.pane, notebookView }),
    toggleLeftPane: () => setPane({ ...state.pane, leftOpen: !state.pane.leftOpen }),
    toggleRightPane: () => setPane({ ...state.pane, rightOpen: !state.pane.rightOpen }),
    setActiveHeading: (id) => setState('activeHeadingId', id),
    setSearchOpen: (open) => setState('searchOpen', open),
    setSearchEngineEnabled: (enabled) => setState('searchEngineEnabled', enabled),
    reloadSearchEngineCapability: loadSearchEngineCapability,
    setMessage,
    dismissError: () => setState('error', ''),
    refreshCatalog: async () => {
      await refreshCatalog()
      // Reload every notebook whose notes are already on screen — the open
      // notebook and any expanded tree groups — instead of wiping the map and
      // leaving the other groups empty until they are collapsed and reopened.
      const loaded = new Set(Object.keys(state.notesByNotebook))
      if (state.notebookId) loaded.add(state.notebookId)
      await Promise.all([...loaded].map((id) => loadNotes(asNotebookId(id))))
      await refreshNote()
    },
    signInWithKey: async (key) => {
      settingsSave.reset()
      ocrTasks.clear()
      documentViews.clear()
      readerRoute = rememberReaderRoute(state.route)
      writeReaderRoute(readerRoute, readerStorage)
      client.useCredential(key)
      setState({ auth: 'unknown', error: '', message: '' })
      await refreshCatalog()
      if (state.auth === 'authenticated') {
        await loadSearchEngineCapability()
        return
      }
      // A refused key must not linger: the next request would answer 401 and
      // the login view would look broken rather than unaccepted.
      client.clearCredential()
      setState('auth', 'unauthenticated')
      throw new Error(state.error || 'That API key was refused.')
    },
    refreshNote,
    loadNotes,
    loadMoreNotes,
    canLoadMoreNotes,
    notesLoadState: (notebookId) => noteLoadStates[notebookId] ?? 'idle',
    setNotebookReadOnly: async (notebookId, readOnly) => {
      const notebook = state.notebooks.find((candidate) => candidate.notebookId === notebookId)
      if (!notebook) {
        setMessage('Could not change notebook access: notebook is not loaded.', 'error')
        return
      }
      await readOnlyController.set(notebook, readOnly)
    },
    deselectNote: () => {
      if (state.route.kind === 'fast') { store.openFastNotes(); return }
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
    case 'tasks': return 'tasks'
    case 'fast': return `fast:${route.noteId ?? 'feed'}`
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

/** Only a transport-level 401 means "not logged in". A GraphQL-level failure
 * or a network drop must keep its own reporting path. */
export function isUnauthorized(error: unknown): boolean {
  return error instanceof NoteTransportError && error.kind === 'http' && error.status === 401
}
