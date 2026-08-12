import { createContext, onCleanup, useContext, type JSX } from 'solid-js'
import { createStore, produce } from 'solid-js/store'
import { NoteGraphQLClient } from '../notes/client'
import { subscribeNoteEvents } from '../notes/events'
import { loadNotebookPages } from '../notes/paging'
import type { Note, Notebook, NoteTag, NoteTagClass } from '../notes/types'
import {
  browserRouterEnvironment,
  formatRoute,
  navigate,
  parseRoute,
  subscribeRoute,
  withConversation,
  type Route,
  type RouterEnvironment,
} from '../router'
import {
  browserPaneStorage,
  readPaneState,
  withLeftTab,
  withRightTab,
  writePaneState,
  type LeftTab,
  type PaneState,
  type PaneStateStorage,
  type RightTab,
} from './paneState'

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
}

export interface AppStore {
  state: AppState
  client: NoteGraphQLClient
  notes(): Note[]
  notebook(): Notebook | undefined
  conversationId(): string | undefined
  openNote(noteId: string, notebookId?: string): void
  openNotebook(notebookId: string): void
  openBoard(): void
  openHome(): void
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
  })

  let catalogGeneration = 0
  let noteGeneration = 0
  let catalogTimer: ReturnType<typeof setTimeout> | undefined

  const setPane = (next: PaneState) => {
    setState('pane', next)
    writePaneState(next, paneStorage)
  }

  const bumpNotebook = (notebookId: string) => {
    setState('notebookRevisions', notebookId, (revision) => (revision ?? 0) + 1)
  }

  const loadNotes = async (notebookId: string): Promise<void> => {
    try {
      const notes = await client.notes(notebookId, 0)
      setState('notesByNotebook', notebookId, notes)
    } catch (error) {
      setState('message', `Could not load notes: ${errorMessage(error)}`)
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
      setState({ notebookId: route.notebookId, noteId: undefined, note: undefined, activeHeadingId: '' })
      await loadNotes(route.notebookId)
      if (generation !== noteGeneration) return
      const first = state.notesByNotebook[route.notebookId]?.[0]
      if (first) openNote(first.noteId, route.notebookId)
      return
    }
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

  const scheduleCatalogRefresh = () => {
    if (catalogTimer) return
    catalogTimer = setTimeout(() => {
      catalogTimer = undefined
      void refreshCatalog()
    }, 400)
  }

  let appliedSelection = ''
  const unsubscribeRoute = subscribeRoute(router, (route) => {
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
  })

  const store: AppStore = {
    state,
    client,
    notes: () => (state.notebookId ? state.notesByNotebook[state.notebookId] ?? [] : []),
    notebook: () => state.notebooks.find((notebook) => notebook.notebookId === state.notebookId),
    conversationId,
    openNote,
    openNotebook: (notebookId) => go({ kind: 'notebook', notebookId }),
    openBoard: () => go({ kind: 'board' }),
    openHome: () => go({ kind: 'home' }),
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
    case 'board': return 'board'
    default: return 'home'
  }
}

function toggle(values: string[], value: string): string[] {
  return values.includes(value) ? values.filter((entry) => entry !== value) : [...values, value]
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
