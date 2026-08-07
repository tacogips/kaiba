import {
  For,
  Show,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
} from 'solid-js'
import { NoteGraphQLClient } from '../notes/client'
import { NoteWorkspaceClient } from '../notes/workspace'
import { NoteComposePanel, type NoteComposeDestination } from '../components/NoteComposePanel'
import {
  createdBoundInputIsValid,
  createdBounds,
  createdRangeOptions,
  type CreatedRange,
} from '../notes/createdFilter'
import { NoteDetailPane } from '../components/NoteDetailPane'
import { NoteSearchPopup } from '../components/NoteSearchPopup'
import '../notes-detail.css'
import {
  NotebookProgressController,
  NotebookReadOnlyController,
  NotebookScopeController,
  constraintForTag,
  pruneNotebookActivatorEntries,
  replaceNotebook,
  stageNotebookUpdate,
  tagRemovalCanAffectConstraints,
  type NotebookConstraint,
  type PendingNotebookCommit,
  type NotebookScope,
} from '../notes/controller'
import {
  NotebookPartialLoadError,
  loadNotebookPages,
  notebookPageLimit,
} from '../notes/paging'
import {
  assignableTagGroups,
  buildFolderTree,
  directFolderAssignments,
  folderNameCollision,
  folderTags,
  groupTagAssignments,
  matchesCreatedFolder,
  navigationTagGroups,
  qualifiedTagBreadcrumb,
  qualifiedTagLabel,
  type TagTreeNode,
} from '../notes/tree'
import type {
  HostMode,
  KanbanStatus,
  KanbanStatusSet,
  Note,
  Notebook,
  NoteListSort,
  NoteTag,
  NoteTagClass,
} from '../notes/types'
import { eventAffectsScope, subscribeNoteEvents } from '../notes/events'

const defaultStatusSet: KanbanStatusSet = {
  setId: 'kanban-default',
  name: 'default',
  isSystem: true,
  statuses: [
    { statusId: 'kanban-default-none', name: 'none', category: 'none', position: 0 },
    { statusId: 'kanban-default-pending', name: 'pending', category: 'pending', position: 1 },
    { statusId: 'kanban-default-progress', name: 'progress', category: 'progress', position: 2 },
    { statusId: 'kanban-default-review', name: 'review', category: 'review', position: 3 },
    { statusId: 'kanban-default-done', name: 'done', category: 'done', position: 4 },
  ],
}

const systemMemoryNotebookKindTagId = 'notebook-kind-system-memory'
const defaultStatusLabels: Record<string, string> = {
  none: 'No status',
  pending: 'Pending',
  progress: 'In progress',
  review: 'In review',
  done: 'Done',
}

export function statusLabel(status: Pick<KanbanStatus, 'name'>): string {
  return defaultStatusLabels[status.name] ?? status.name
}

/** Deterministic client-side fallback grouping: direct name match, else the
 * first column whose category matches the (default-name) category, else the
 * first none-category column, else the first column. Cards are never dropped. */
export function boardColumnIndex(progress: string, statuses: KanbanStatus[]): number {
  const direct = statuses.findIndex((status) => status.name === progress)
  if (direct >= 0) return direct
  const category = defaultStatusSet.statuses.find((status) => status.name === progress)?.category ?? 'none'
  const byCategory = statuses.findIndex((status) => status.category === category)
  if (byCategory >= 0) return byCategory
  const noneColumn = statuses.findIndex((status) => status.category === 'none')
  return noneColumn >= 0 ? noneColumn : 0
}

export function statusCategoryFor(progress: string, statuses: KanbanStatus[]): string {
  return statuses[boardColumnIndex(progress, statuses)]?.category ?? 'none'
}

export function progressLabelFor(progress: string, statuses: KanbanStatus[]): string {
  const direct = statuses.find((status) => status.name === progress)
  if (direct) return statusLabel(direct)
  return defaultStatusLabels[progress] ?? progress
}

const boardLockStoragePrefix = 'kaiba-note-board-lock:'
type RefreshOutcome = 'completed' | 'failed' | 'superseded'

export function NotesView(props: {
  mode: HostMode
  profileName?: string
  onExpandNotebook?: (notebookId: string, notebookTitle: string) => void
  onAskAgent?: (payload: { noteId: string; title: string; bodyMarkdown: string }) => void
}) {
  const client = new NoteGraphQLClient(props.mode)
  // The REST note workspace only exists when RielaApp hosts the web app; in
  // cli-serve mode the pane stays on the GraphQL read-only preview.
  const workspace = new NoteWorkspaceClient(() => props.profileName ?? '')
  const workspaceEnabled = () => props.mode === 'riela-app'
  const scopeController = new NotebookScopeController()
  const [tags, setTags] = createSignal<NoteTag[]>([])
  const [tagClasses, setTagClasses] = createSignal<NoteTagClass[]>([])
  const [notebooks, setNotebooks] = createSignal<Notebook[]>([])
  const [activeScope, setActiveScope] = createSignal<NotebookScope>(scopeController.current())
  const [navigationTab, setNavigationTab] = createSignal<'folder' | 'tags'>('folder')
  const [expanded, setExpanded] = createSignal<Set<string>>(new Set())
  const [expandedTagGroups, setExpandedTagGroups] = createSignal<Set<string>>(new Set())
  const [view, setView] = createSignal<'list' | 'board'>('list')
  // Value equality keeps the signal referentially stable across refreshes so
  // board sections are not re-created mid-drag when the set has not changed.
  const [statusSet, setStatusSet] = createSignal<KanbanStatusSet>(defaultStatusSet, {
    equals: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  })
  const [kanbanSets, setKanbanSets] = createSignal<KanbanStatusSet[]>([], {
    equals: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  })
  const [boardLocked, setBoardLocked] = createSignal(true)
  const [sort, setSort] = createSignal<NoteListSort>('updatedAtDesc')
  const [createdRange, setCreatedRange] = createSignal<CreatedRange>('any')
  const [customCreatedAfter, setCustomCreatedAfter] = createSignal('')
  const [customCreatedBefore, setCustomCreatedBefore] = createSignal('')
  const [loading, setLoading] = createSignal(true)
  const [draggingNotebookId, setDraggingNotebookId] = createSignal<string>()
  const [error, setError] = createSignal('')
  const [message, setMessage] = createSignal('')
  const [selectedNotebookId, setSelectedNotebookId] = createSignal<string>()
  // A note opened from search or from a link can live outside the active scope;
  // its notebook is fetched on demand so the detail aside can still render it.
  const [externalNotebook, setExternalNotebook] = createSignal<Notebook>()
  const [notebookLockBusy, setNotebookLockBusy] = createSignal(false)
  const [activeNoteId, setActiveNoteId] = createSignal<string>()
  const [searchOpen, setSearchOpen] = createSignal(false)
  const [composeDestination, setComposeDestination] = createSignal<NoteComposeDestination>()
  const [preview, setPreview] = createSignal<Note[]>([])
  const [previewOffset, setPreviewOffset] = createSignal(0)
  const [previewHasMore, setPreviewHasMore] = createSignal(false)
  const [previewLoading, setPreviewLoading] = createSignal(false)
  const [newFolderName, setNewFolderName] = createSignal('')
  const [creatingFolder, setCreatingFolder] = createSignal(false)
  const [membershipBusy, setMembershipBusy] = createSignal('')
  const [focusedTagId, setFocusedTagId] = createSignal<string>()
  const [addGroupKey, setAddGroupKey] = createSignal('')
  const [addTagId, setAddTagId] = createSignal('')
  const notebookActivators = new Map<string, HTMLButtonElement>()
  let detailReturnNotebookId: string | undefined
  let loadGeneration = 0
  let previewGeneration = 0
  let pendingNotebookCommit: PendingNotebookCommit | undefined
  let clearAllButton: HTMLButtonElement | undefined
  let contentHeading: HTMLDivElement | undefined

  const publishNotebookMutation = (notebook: Notebook): Notebook => {
    const reconciled = readOnlyController.visible(controller.visible(notebook))
    if (draggingNotebookId()) {
      pendingNotebookCommit = stageNotebookUpdate(
        notebooks(),
        pendingNotebookCommit,
        reconciled,
        loadGeneration,
      )
    } else {
      setNotebooks((current) => replaceNotebook(current, reconciled))
    }
    if (externalNotebook()?.notebookId === reconciled.notebookId) setExternalNotebook(reconciled)
    return reconciled
  }

  const controller = new NotebookProgressController(
    {
      setProgress: (notebookId, progress) => client.setProgress(notebookId, progress),
      readNotebook: (notebookId) => client.notebook(notebookId),
    },
    (updated, mutationError) => {
      publishNotebookMutation(updated)
      if (mutationError) setMessage(`Progress reconciled to the server value: ${mutationError}`)
    },
  )

  const readOnlyController = new NotebookReadOnlyController(
    {
      setReadOnly: (notebookId, readOnly) => client.setNotebookReadOnly(notebookId, readOnly),
    },
    (updated, mutationError) => {
      const reconciled = publishNotebookMutation(updated)
      if (selectedNotebookId() !== updated.notebookId) return
      setMessage(mutationError
        ? `Could not change notebook lock: ${mutationError}`
        : reconciled.readOnly ? 'System memory is locked.' : 'System memory is unlocked.')
    },
  )

  const publishNotebooks = (accepted: Notebook[], generation: number) => {
    if (generation !== loadGeneration) return
    const draggingId = draggingNotebookId()
    // Only defer the commit while the dragged card still exists in the incoming
    // list; if the drag source has left the scope its dragend can never fire
    // (Chromium does not dispatch dragend on a disconnected node), so publishing
    // now — and clearing the stale drag — prevents a permanently frozen list.
    if (draggingId && accepted.some((notebook) => notebook.notebookId === draggingId)) {
      pendingNotebookCommit = { generation, notebooks: accepted }
      return
    }
    if (draggingId) setDraggingNotebookId(undefined)
    pendingNotebookCommit = undefined
    setNotebooks(accepted)
    pruneNotebookActivatorEntries(
      notebookActivators,
      accepted.map((notebook) => notebook.notebookId),
    )
  }

  const finishNotebookDrag = () => {
    setDraggingNotebookId(undefined)
    const pending = pendingNotebookCommit
    pendingNotebookCommit = undefined
    if (!pending || pending.generation !== loadGeneration) return
    setNotebooks(pending.notebooks)
    pruneNotebookActivatorEntries(
      notebookActivators,
      pending.notebooks.map((notebook) => notebook.notebookId),
    )
  }

  const folders = createMemo(() => folderTags(tags()))
  const tree = createMemo(() => buildFolderTree(tags()))
  const tagGroups = createMemo(() => navigationTagGroups(tags(), tagClasses()))
  const pickerGroups = createMemo(() =>
    assignableTagGroups(tags(), tagClasses()).filter((group) => group.knownClass))
  const selectedFolderId = createMemo(() => {
    const constraints = activeScope().constraints
    return constraints.length === 1 && constraints[0]?.kind === 'folder'
      ? constraints[0].tagId
      : undefined
  })
  const selectedTagId = createMemo(() => {
    const constraints = activeScope().constraints
    return constraints.length === 1 && constraints[0]?.kind === 'tag'
      ? constraints[0].tagId
      : undefined
  })
  const activeConstraintIds = createMemo(() =>
    new Set(activeScope().constraints.map((constraint) => constraint.tagId)))
  const scopeTagId = createMemo(() => {
    const constraints = activeScope().constraints
    return constraints.length === 1 ? constraints[0]?.tagId : undefined
  })
  const boardLockKey = () => `${boardLockStoragePrefix}${scopeTagId() ?? '*'}`
  const loadBoardLock = () => {
    try {
      setBoardLocked(localStorage.getItem(boardLockKey()) !== 'unlocked')
    } catch {
      setBoardLocked(true)
    }
  }
  const toggleBoardLock = () => {
    const next = !boardLocked()
    setBoardLocked(next)
    try {
      localStorage.setItem(boardLockKey(), next ? 'locked' : 'unlocked')
    } catch {
      // Persistence is best-effort; the toggle still applies to this session.
    }
  }
  const boardStatuses = createMemo(() => statusSet().statuses)
  const boardColumnAssignments = createMemo(() => {
    const statuses = boardStatuses()
    const assignments = new Map<string, Notebook[]>(statuses.map((status) => [status.name, []]))
    if (statuses.length === 0) return assignments
    for (const notebook of notebooks()) {
      const status = statuses[boardColumnIndex(notebook.progress, statuses)]
      if (status) assignments.get(status.name)?.push(notebook)
    }
    return assignments
  })
  const selectedFolder = createMemo(() => folders().find((tag) => tag.tagId === selectedFolderId()))
  const selectedScopeTag = createMemo(() => tags().find((tag) => tag.tagId === selectedTagId()))
  const selectedNotebook = createMemo(() => {
    const notebookId = selectedNotebookId()
    const inScope = notebooks().find((notebook) => notebook.notebookId === notebookId)
    if (inScope) return inScope
    const external = externalNotebook()
    return external?.notebookId === notebookId ? external : undefined
  })
  const activeFolderTreeTagId = createMemo(() => {
    const focused = focusedTagId()
    if (focused && folders().some((tag) => tag.tagId === focused)) return focused
    return selectedFolderId() ?? tree()[0]?.tag.tagId
  })
  const hasFolderClass = createMemo(() => tagClasses().some((tagClass) => tagClass.classId === 'folder'))
  const folderPath = createMemo(() => qualifiedTagBreadcrumb(tags(), selectedFolderId()))
  const tagLabel = (tag: Pick<NoteTag, 'tagId'>) => qualifiedTagLabel(tags(), tag.tagId)
  const selectedTagGroup = createMemo(() =>
    tagGroups().find((group) => group.classId === selectedScopeTag()?.classId))
  const selectedTagPath = createMemo(() => {
    const selected = selectedScopeTag()
    if (!selected) return []
    return qualifiedTagBreadcrumb(tags(), selected.tagId)
  })
  const assignmentGroups = createMemo(() =>
    groupTagAssignments(selectedNotebook()?.tags ?? [], tagClasses()))
  const folderAssignments = createMemo(() =>
    assignmentGroups().find((group) => group.classId === 'folder'))
  const nonFolderAssignmentGroups = createMemo(() =>
    assignmentGroups().filter((group) => group.classId !== 'folder'))
  const selectedPickerGroup = createMemo(() =>
    pickerGroups().find((group) => group.key === addGroupKey()))
  const assignedTagIds = createMemo(() =>
    new Set(selectedNotebook()?.tags.map((assignment) => assignment.tag.tagId) ?? []))
  const assignableTags = createMemo(() =>
    selectedPickerGroup()?.tags.filter((tag) => !assignedTagIds().has(tag.tagId)) ?? [])
  const activeGroupTreeTagId = (
    groupTags: NoteTag[],
    fallbackTagId: string | undefined,
  ): string | undefined => {
    const focused = focusedTagId()
    if (focused && groupTags.some((tag) => tag.tagId === focused)) return focused
    return fallbackTagId
  }

  onMount(() => {
    loadBoardLock()
    void refresh({ initialize: true })
    let refreshTimer: ReturnType<typeof setTimeout> | undefined
    let firstConnect = true
    const scheduleEventRefresh = () => {
      if (refreshTimer) return
      refreshTimer = setTimeout(() => {
        refreshTimer = undefined
        void refresh()
      }, 400)
    }
    const unsubscribe = subscribeNoteEvents({
      headers: () => client.streamHeaders(),
      onEvent: (event) => {
        const names = activeScope().constraints.map((constraint) => constraint.tagName)
        if (eventAffectsScope(event, names)) scheduleEventRefresh()
      },
      onConnect: () => {
        // Refresh once on every (re)connect so missed events can never leave
        // stale state; the initial mount refresh covers the first connect.
        if (firstConnect) { firstConnect = false; return }
        scheduleEventRefresh()
      },
    })
    onCleanup(() => {
      unsubscribe()
      if (refreshTimer) clearTimeout(refreshTimer)
    })
    // Safety net: a drag that ends outside any board column (or in List view,
    // which has no drop targets) must still release the deferred list commit.
    const releaseDrag = () => { if (draggingNotebookId()) finishNotebookDrag() }
    document.addEventListener('dragend', releaseDrag)
    document.addEventListener('drop', releaseDrag)
    onCleanup(() => {
      document.removeEventListener('dragend', releaseDrag)
      document.removeEventListener('drop', releaseDrag)
    })
    // Browser-safe subset of the native shortcut set: `/` opens search (⌘F
    // equivalent), `n` composes a memo (⌘N) and `N` a note in the selected
    // notebook (⇧⌘N). Only when the workspace exists and no field is focused.
    const shortcutHandler = (event: KeyboardEvent) => {
      if (!workspaceEnabled() || event.metaKey || event.ctrlKey || event.altKey) return
      const target = event.target as HTMLElement | null
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'SELECT' || target.isContentEditable)) return
      if (event.key === '/') {
        event.preventDefault()
        setSearchOpen(true)
      } else if (event.key === 'n') {
        event.preventDefault()
        setComposeDestination('memo')
      } else if (event.key === 'N' && selectedNotebookId()) {
        event.preventDefault()
        setComposeDestination('notebook')
      }
    }
    window.addEventListener('keydown', shortcutHandler)
    onCleanup(() => window.removeEventListener('keydown', shortcutHandler))
  })

  const refresh = async (
    options: { initialize?: boolean; clearMembership?: boolean } = {},
  ): Promise<RefreshOutcome> => {
    const generation = ++loadGeneration
    pendingNotebookCommit = undefined
    let scopeSnapshot = scopeController.snapshot()
    const progressSnapshot = controller.snapshot()
    const readOnlySnapshot = readOnlyController.snapshot()
    let acceptedPartialNotebooks: Notebook[] | undefined
    if (options.clearMembership) {
      setDraggingNotebookId(undefined)
      setNotebooks([])
      pruneNotebookActivatorEntries(notebookActivators, [])
    }
    setLoading(true)
    setError('')
    try {
      if (options.initialize) await client.initialize()
      // No local credential is not fatal: an --allow-unauthenticated kaiba
      // serve host accepts the request anyway, and an auth-required host
      // rejects it with a registration hint carried in the 401 body.
      const scopeConstraints = scopeSnapshot.scope.constraints
      const scopeTag = scopeConstraints.length === 1 ? scopeConstraints[0]?.tagId : undefined
      const [nextTags, classes, effectiveSet, allSets] = await Promise.all([
        client.tags(),
        client.tagClasses(),
        (scopeTag
          ? client.effectiveKanbanStatusesByTagId(scopeTag)
          : client.effectiveKanbanStatuses()).catch(() => defaultStatusSet),
        client.kanbanStatusSets().catch(() => []),
      ])
      if (generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) return 'superseded'
      setStatusSet(effectiveSet.statuses.length > 0 ? effectiveSet : defaultStatusSet)
      setKanbanSets(allSets)
      const hadActiveConstraints = scopeSnapshot.scope.constraints.length > 0
      const reconciled = scopeController.reconcile(nextTags)
      const catalogClearedScope = hadActiveConstraints
        && reconciled.scope.constraints.length === 0
      if (!scopeController.isCurrent(scopeSnapshot)) {
        scopeSnapshot = reconciled
        setActiveScope(scopeSnapshot.scope)
      }
      if (catalogClearedScope) {
        setSelectedNotebookId(undefined)
        setExternalNotebook(undefined)
        setActiveNoteId(undefined)
        detailReturnNotebookId = undefined
        setDraggingNotebookId(undefined)
        previewGeneration += 1
        setPreview([])
        setPreviewOffset(0)
        setPreviewHasMore(false)
        setPreviewLoading(false)
        setAddGroupKey('')
        setAddTagId('')
        setNotebooks([])
        pruneNotebookActivatorEntries(notebookActivators, [])
      }
      setTags(nextTags)
      setTagClasses(classes)
      const nextNotebooks = await loadNotebookPages(
        client,
        sort(),
        scopeController.tagFilterIdGroups(scopeSnapshot),
        () => generation === loadGeneration && scopeController.isCurrent(scopeSnapshot),
        (values) => {
          acceptedPartialNotebooks = values
        },
        undefined,
        createdBounds(createdRange(), customCreatedAfter(), customCreatedBefore()),
      )
      if (!nextNotebooks || generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) {
        return 'superseded'
      }
      publishNotebooks(
        nextNotebooks.map((notebook) => readOnlyController.adopt(
          controller.adopt(notebook, progressSnapshot),
          readOnlySnapshot,
        )),
        generation,
      )
      return 'completed'
    } catch (refreshError) {
      if (generation !== loadGeneration || !scopeController.isCurrent(scopeSnapshot)) return 'superseded'
      if (refreshError instanceof NotebookPartialLoadError) {
        publishNotebooks(
          (acceptedPartialNotebooks ?? refreshError.notebooks)
            .map((notebook) => readOnlyController.adopt(
              controller.adopt(notebook, progressSnapshot),
              readOnlySnapshot,
            )),
          generation,
        )
      }
      setError(errorMessage(refreshError))
      return 'failed'
    } finally {
      if (generation === loadGeneration && scopeController.isCurrent(scopeSnapshot)) setLoading(false)
    }
  }

  const beginScope = (constraint?: NotebookConstraint, append = false) => {
    loadGeneration += 1
    pendingNotebookCommit = undefined
    setDraggingNotebookId(undefined)
    const snapshot = append && constraint
      ? scopeController.add(constraint)
      : scopeController.select(constraint)
    setActiveScope(snapshot.scope)
    setSelectedNotebookId(undefined)
    setExternalNotebook(undefined)
    setActiveNoteId(undefined)
    detailReturnNotebookId = undefined
    previewGeneration += 1
    setPreview([])
    setNotebooks([])
    loadBoardLock()
  }

  const selectScope = (tag?: NoteTag) => {
    beginScope(tag ? constraintForTag(tag) : undefined)
    void refresh()
  }

  const addScope = (tag: NoteTag) => {
    beginScope(constraintForTag(tag), true)
    void refresh()
  }

  const removeScope = (tagId: string) => {
    loadGeneration += 1
    pendingNotebookCommit = undefined
    setDraggingNotebookId(undefined)
    const snapshot = scopeController.remove(tagId)
    setActiveScope(snapshot.scope)
    setSelectedNotebookId(undefined)
    setExternalNotebook(undefined)
    setActiveNoteId(undefined)
    detailReturnNotebookId = undefined
    previewGeneration += 1
    setPreview([])
    setNotebooks([])
    void refresh()
  }

  const clearScope = () => {
    beginScope()
    void refresh()
  }

  // Mirrors the native root-hosted unsaved-edit guard: every selection path
  // confirms before discarding an in-flight body edit.
  let detailDirty = false
  const confirmDiscardIfDirty = (): boolean => {
    if (!detailDirty) return true
    const discard = window.confirm('Discard unsaved note changes?')
    if (discard) detailDirty = false
    return discard
  }

  const selectNotebook = async (notebook: Notebook, activator?: HTMLButtonElement) => {
    if (selectedNotebookId() !== notebook.notebookId && !confirmDiscardIfDirty()) return
    previewGeneration += 1
    detailReturnNotebookId = notebook.notebookId
    if (activator) notebookActivators.set(notebook.notebookId, activator)
    setSelectedNotebookId(notebook.notebookId)
    setExternalNotebook(undefined)
    setActiveNoteId(undefined)
    setPreview([])
    setPreviewOffset(0)
    setPreviewHasMore(false)
    setAddGroupKey('')
    setAddTagId('')
    // The reader pane loads notes over REST; the GraphQL preview is only the
    // cli-serve fallback, so it is not fetched when the pane is available.
    if (workspaceEnabled()) return
    await loadPreview(notebook.notebookId, 0, false, previewGeneration)
  }

  /** Opens a note found through search or a link, pulling in its notebook when
   * that notebook is outside the active scope. */
  const openNote = async (noteId: string, notebookId: string) => {
    if (activeNoteId() !== noteId && !confirmDiscardIfDirty()) return
    previewGeneration += 1
    setActiveNoteId(noteId)
    setAddGroupKey('')
    setAddTagId('')
    setPreview([])
    setPreviewHasMore(false)
    if (selectedNotebookId() === notebookId) return
    detailReturnNotebookId = notebookId
    setSelectedNotebookId(notebookId)
    if (notebooks().some((notebook) => notebook.notebookId === notebookId)) {
      setExternalNotebook(undefined)
      return
    }
    try {
      const progressSnapshot = controller.snapshot()
      const readOnlySnapshot = readOnlyController.snapshot()
      const notebook = await client.notebook(notebookId)
      if (selectedNotebookId() !== notebookId) return
      setExternalNotebook(readOnlyController.adopt(
        controller.adopt(notebook, progressSnapshot),
        readOnlySnapshot,
      ))
    } catch (notebookError) {
      setMessage(`Could not open that note's notebook: ${errorMessage(notebookError)}`)
    }
  }

  const createNote = async (destination: NoteComposeDestination, bodyMarkdown: string) => {
    const notebookId = selectedNotebookId()
    if (destination === 'notebook' && selectedNotebook()?.readOnly) {
      setMessage('Unlock this notebook before adding notes.')
      return
    }
    const detail = destination === 'memo' || !notebookId
      ? await workspace.createMemo(bodyMarkdown)
      : await workspace.createNote(notebookId, bodyMarkdown)
    setComposeDestination(undefined)
    setMessage(`Created “${detail.note.title ?? `Note ${detail.note.noteNumber}`}”.`)
    await openNote(detail.note.noteId, detail.note.notebookId)
    await refresh()
  }

  const toggleNotebookReadOnly = async (notebook: Notebook) => {
    setNotebookLockBusy(true)
    try {
      await readOnlyController.set(notebook, !notebook.readOnly)
    } finally {
      setNotebookLockBusy(false)
    }
  }

  const closeDetail = (restoreFocus = true) => {
    // Only user-initiated closes prompt; background reconciliation (a vanished
    // notebook or scope change) must never block on a confirm dialog.
    if (restoreFocus && !confirmDiscardIfDirty()) return
    detailDirty = false
    previewGeneration += 1
    const notebookId = detailReturnNotebookId
    setSelectedNotebookId(undefined)
    setExternalNotebook(undefined)
    setActiveNoteId(undefined)
    setPreview([])
    setPreviewHasMore(false)
    setPreviewLoading(false)
    setAddGroupKey('')
    setAddTagId('')
    detailReturnNotebookId = undefined
    if (!restoreFocus || !notebookId) return
    queueMicrotask(() => {
      const activator = notebookActivators.get(notebookId)
      if (activator?.isConnected) activator.focus()
    })
  }

  const loadPreview = async (
    notebookId: string,
    offset: number,
    append: boolean,
    generation = previewGeneration,
  ) => {
    setPreviewLoading(true)
    try {
      const values = await client.notes(notebookId, offset)
      if (selectedNotebookId() !== notebookId || generation !== previewGeneration) return
      setPreview((current) => append ? [...current, ...values] : values)
      setPreviewOffset(offset + values.length)
      setPreviewHasMore(values.length === notebookPageLimit)
    } catch (previewError) {
      if (selectedNotebookId() !== notebookId || generation !== previewGeneration) return
      setMessage(`Could not load notes: ${errorMessage(previewError)}`)
    } finally {
      if (selectedNotebookId() === notebookId && generation === previewGeneration) {
        setPreviewLoading(false)
      }
    }
  }

  const createFolder = async () => {
    const name = newFolderName().trim()
    if (!name) return
    const parentTagId = selectedFolderId()
    const scopeSnapshot = scopeController.snapshot()
    const shouldEnterCreatedFolder = scopeSnapshot.scope.constraints.length === 1
      && scopeSnapshot.scope.constraints[0]?.kind === 'folder'
      && scopeSnapshot.scope.constraints[0].tagId === parentTagId
    const collision = folderNameCollision(tags(), name, parentTagId)
    if (collision) {
      setMessage(`A sibling folder named “${name}” already exists at ${tagLabel(collision)}.`)
      return
    }
    setCreatingFolder(true)
    setMessage('')
    try {
      const created = await client.defineFolder(name, 'folder', parentTagId)
      if (!matchesCreatedFolder(created, 'folder', parentTagId)) {
        throw new Error('The returned folder did not match the requested class and parent.')
      }
      setTags((current) =>
        current.some((tag) => tag.tagId === created.tagId) ? current : [...current, created])
      setExpanded((current) => new Set(current).add(parentTagId ?? created.tagId))
      setNewFolderName('')
      setMessage(`Created folder “${tagLabel(created)}”.`)
      if (shouldEnterCreatedFolder && scopeController.isCurrent(scopeSnapshot)) {
        beginScope(constraintForTag(created))
        await refresh()
      }
    } catch (creationError) {
      setMessage(errorMessage(creationError))
      try {
        setTags(await client.tags())
      } catch {
        // Keep the creation error as the actionable message.
      }
    } finally {
      setCreatingFolder(false)
    }
  }

  const moveProgress = async (notebook: Notebook, progress: string) => {
    setMessage('')
    await controller.move(notebook, progress)
  }

  const applyExistingTag = async (tag: NoteTag) => {
    const notebook = selectedNotebook()
    if (!notebook || membershipBusy()) return
    const scopeSnapshot = scopeController.snapshot()
    const progressSnapshot = controller.snapshot()
    const readOnlySnapshot = readOnlyController.snapshot()
    const currentTag = tags().find((candidate) =>
      candidate.tagId === tag.tagId && candidate.name === tag.name && candidate.classId === tag.classId)
    if (!currentTag || assignedTagIds().has(currentTag.tagId)) {
      setMessage('That tag is no longer assignable. Refreshing the tag catalog.')
      await refresh()
      return
    }
    const busyKey = `add:${notebook.notebookId}:${currentTag.tagId}`
    setMembershipBusy(busyKey)
    setMessage('')
    try {
      const updated = await client.applyTagById(notebook.notebookId, currentTag.tagId)
      if (selectedNotebookId() !== notebook.notebookId
          || !scopeController.isCurrent(scopeSnapshot)) {
        await refresh()
        return
      }
      const reconciled = readOnlyController.adopt(
        controller.adopt(updated, progressSnapshot),
        readOnlySnapshot,
      )
      setNotebooks((current) => replaceNotebook(current, reconciled))
      setAddTagId('')
      setMessage(`Added “${tagLabel(currentTag)}”.`)
      await refresh()
    } catch (membershipError) {
      if (selectedNotebookId() === notebook.notebookId) setMessage(errorMessage(membershipError))
    } finally {
      if (membershipBusy() === busyKey) setMembershipBusy('')
    }
  }

  const removeTag = async (tag: NoteTag) => {
    const notebook = selectedNotebook()
    if (!notebook || membershipBusy()) return
    const scopeSnapshot = scopeController.snapshot()
    const progressSnapshot = controller.snapshot()
    const readOnlySnapshot = readOnlyController.snapshot()
    const busyKey = `remove:${notebook.notebookId}:${tag.tagId}`
    setMembershipBusy(busyKey)
    setMessage('')
    try {
      const updated = await client.removeTagById(notebook.notebookId, tag.tagId)
      if (selectedNotebookId() !== notebook.notebookId
          || !scopeController.isCurrent(scopeSnapshot)) {
        const currentScope = scopeController.current()
        const currentDetailNotebookId = selectedNotebookId()
        const clearMembership = tagRemovalCanAffectConstraints(
          tag,
          currentScope.constraints,
          tags(),
        )
        const refreshOutcome = await refresh({ clearMembership })
        if (clearMembership
            && currentDetailNotebookId
            && refreshOutcome !== 'superseded'
            && selectedNotebookId() === currentDetailNotebookId) {
          const detailRemainsVisible = refreshOutcome === 'completed'
            && notebooks().some((item) => item.notebookId === currentDetailNotebookId)
          if (detailRemainsVisible) {
            focusAfterScopeEjection(
              notebooks(),
              notebookActivators,
              clearAllButton,
              contentHeading,
              currentDetailNotebookId,
            )
          } else {
            closeDetail(false)
            focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
          }
        }
        return
      }
      const reconciled = readOnlyController.adopt(
        controller.adopt(updated, progressSnapshot),
        readOnlySnapshot,
      )
      setNotebooks((current) => replaceNotebook(current, reconciled))
      const clearMembership = tagRemovalCanAffectConstraints(
        tag,
        scopeSnapshot.scope.constraints,
        tags(),
      )
      const refreshOutcome = await refresh({ clearMembership })
      if (refreshOutcome === 'superseded') return
      if (refreshOutcome === 'failed') {
        const removingCurrentDetail = selectedNotebookId() === notebook.notebookId
        if (clearMembership && removingCurrentDetail) {
          closeDetail(false)
          focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
        }
        if (removingCurrentDetail) {
          setMessage(`Removed “${tag.name}”, but the notebook scope could not be refreshed.`)
        }
        return
      }
      if (!notebooks().some((item) => item.notebookId === notebook.notebookId)) {
        if (selectedNotebookId() === notebook.notebookId) {
          closeDetail(false)
          focusAfterScopeEjection(notebooks(), notebookActivators, clearAllButton, contentHeading)
        }
        if (!selectedNotebookId() || selectedNotebookId() === notebook.notebookId) {
          setMessage(`Removed “${tag.name}”; the notebook left the active filter.`)
        }
      } else if (selectedNotebookId() === notebook.notebookId) {
        setMessage(`Removed “${tag.name}”.`)
      }
    } catch (membershipError) {
      if (selectedNotebookId() === notebook.notebookId) setMessage(errorMessage(membershipError))
    } finally {
      if (membershipBusy() === busyKey) setMembershipBusy('')
    }
  }

  const availableFolders = createMemo(() => {
    const assigned = new Set(selectedNotebook() ? directFolderAssignments(selectedNotebook()!).map((tag) => tag.tagId) : [])
    return folders().filter((folder) => !assigned.has(folder.tagId))
  })
  const registerNotebookActivator = (notebookId: string, element: HTMLButtonElement) => {
    notebookActivators.set(notebookId, element)
    onCleanup(() => {
      if (notebookActivators.get(notebookId) === element) notebookActivators.delete(notebookId)
    })
  }

  return <section class="notes-workspace">
    <aside class="folder-pane" aria-label="Notes navigation">
      <div class="folder-pane-header"><span class="eyebrow">NOTES</span><h1>Workspace</h1></div>
      <div class="folder-tab" role="tablist" aria-label="Notes navigation mode">
        <button role="tab" aria-selected={navigationTab() === 'folder'} classList={{ active: navigationTab() === 'folder' }} onClick={() => setNavigationTab('folder')}>Folder</button>
        <button role="tab" aria-selected={navigationTab() === 'tags'} classList={{ active: navigationTab() === 'tags' }} onClick={() => setNavigationTab('tags')}>Tags</button>
      </div>
      <button classList={{ 'folder-root': true, selected: activeScope().constraints.length === 0 }} onClick={clearScope}>
        <span aria-hidden="true">▣</span> All notebooks
      </button>
      <Show when={navigationTab() === 'folder'}>
        <div class="folder-tree" role="tree" aria-label="Folder tree">
          <For each={tree()}>{(node) =>
            <TagTreeItem
              node={node}
              level={1}
              expanded={expanded()}
              activeIds={activeConstraintIds()}
              focusedId={activeFolderTreeTagId()}
              icon="▰"
              onToggle={(tagId) => setExpanded((current) => toggleSet(current, tagId))}
              onSelect={selectScope}
              onAdd={addScope}
              onFocus={setFocusedTagId}
              label={tagLabel}
            />}
          </For>
        </div>
        <div class="folder-create">
          <label><span>Create {selectedFolder() ? 'child folder' : 'folder'}</span>
            <input value={newFolderName()} disabled={!hasFolderClass() || creatingFolder()} onInput={(event) => setNewFolderName(event.currentTarget.value)} onKeyDown={(event) => { if (event.key === 'Enter') void createFolder() }} />
          </label>
          <button disabled={!hasFolderClass() || !newFolderName().trim() || creatingFolder()} onClick={() => void createFolder()}>{creatingFolder() ? 'Creating…' : 'Create'}</button>
          <Show when={!hasFolderClass()}><span class="folder-repair">The seeded folder tag class is missing. Repair the Note store before creating folders.</span></Show>
        </div>
      </Show>
      <Show when={navigationTab() === 'tags'}>
        <div class="tag-groups" aria-label="Tag groups">
          <For each={tagGroups()}>{(group) => {
            const isExpanded = () => expandedTagGroups().has(group.key)
            return <section class="tag-group">
              <button class="tag-group-toggle" aria-expanded={isExpanded()} onClick={() => setExpandedTagGroups((current) => toggleSet(current, group.key))}>
                <span>{isExpanded() ? '⌄' : '›'} {group.label}</span><span>{group.tags.length}</span>
              </button>
              <Show when={isExpanded()}>
                <Show when={group.classId !== null} fallback={<div class="folder-tree" role="tree" aria-label={`${group.label} tags`}>
                  <For each={group.tags}>{(tag) => <TagTreeItem node={{ tag, children: [] }} level={1} expanded={expanded()} activeIds={activeConstraintIds()} focusedId={activeGroupTreeTagId(group.tags, group.tags[0]?.tagId)} icon="●" onToggle={() => {}} onSelect={selectScope} onAdd={addScope} onFocus={setFocusedTagId} label={tagLabel} />}</For>
                </div>}>
                  <div class="folder-tree" role="tree" aria-label={`${group.label} tags`}>
                    <For each={group.tree}>{(node) => <TagTreeItem node={node} level={1} expanded={expanded()} activeIds={activeConstraintIds()} focusedId={activeGroupTreeTagId(group.tags, group.tree[0]?.tag.tagId)} icon="◆" onToggle={(tagId) => setExpanded((current) => toggleSet(current, tagId))} onSelect={selectScope} onAdd={addScope} onFocus={setFocusedTagId} label={tagLabel} />}</For>
                  </div>
                </Show>
              </Show>
            </section>
          }}</For>
        </div>
        <KanbanSetManager
          sets={kanbanSets()}
          folders={folders()}
          label={tagLabel}
          onCreate={async (name, statuses) => {
            try {
              await client.createKanbanStatusSet(name, statuses)
              setMessage(`Created status set “${name}”.`)
              await refresh()
            } catch (setError) {
              setMessage(errorMessage(setError))
            }
          }}
          onAssign={async (folderId, setId) => {
            try {
              await client.assignKanbanStatusSetByTagId(folderId, setId)
              const folder = folders().find((candidate) => candidate.tagId === folderId)
              const label = folder ? tagLabel(folder) : folderId
              setMessage(setId ? `Bound status set to “${label}”.` : `Unbound status set from “${label}”.`)
              await refresh()
            } catch (assignError) {
              setMessage(errorMessage(assignError))
            }
          }}
          onDelete={async (setId) => {
            try {
              await client.deleteKanbanStatusSet(setId)
              setMessage('Deleted status set.')
              await refresh()
            } catch (deleteError) {
              setMessage(errorMessage(deleteError))
            }
          }}
        />
      </Show>
    </aside>

    <div class="notes-content">
      <header class="notes-header">
        <div class="notes-breadcrumb" aria-label="Notebook scope breadcrumb">
          <button onClick={clearScope}>All notebooks</button>
          <Show when={activeScope().constraints.length > 1}>
            <span aria-hidden="true">/</span><span>Filtered notebooks</span>
          </Show>
          <Show when={activeScope().constraints.length === 1 && activeScope().constraints[0]?.kind === 'folder'}>
            <For each={folderPath()}>{(segment) => <><span aria-hidden="true">/</span>
              <Show when={segment.tag} fallback={<span>{segment.label}</span>}>{(tag) =>
                <button onClick={() => selectScope(tag())}>{segment.label}</button>}
              </Show>
            </>}</For>
          </Show>
          <Show when={activeScope().constraints.length === 1 && activeScope().constraints[0]?.kind === 'tag'}>
            <span aria-hidden="true">/</span><span>{selectedTagGroup()?.label ?? 'Tags'}</span>
            <For each={selectedTagPath()}>{(segment) => <><span aria-hidden="true">/</span>
              <Show when={segment.tag} fallback={<span>{segment.label}</span>}>{(tag) =>
                <button onClick={() => selectScope(tag())}>{segment.label}</button>}
              </Show>
            </>}</For>
          </Show>
        </div>
        <div class="notes-toolbar">
          <div class="view-tabs" role="tablist" aria-label="Notebook view">
            <button role="tab" aria-selected={view() === 'list'} classList={{ active: view() === 'list' }} onClick={() => setView('list')}>List</button>
            <button role="tab" aria-selected={view() === 'board'} classList={{ active: view() === 'board' }} onClick={() => setView('board')}>Board</button>
          </div>
          <label class="sort-control"><span>Sort</span><select value={sort()} onChange={(event) => { setSort(event.currentTarget.value as NoteListSort); void refresh() }}>
            <option value="updatedAtDesc">Recently updated</option><option value="title">Title</option><option value="createdAtDesc">Newest</option><option value="createdAtAsc">Oldest</option>
          </select></label>
          <label class="sort-control"><span>Created</span><select value={createdRange()} onChange={(event) => { setCreatedRange(event.currentTarget.value as CreatedRange); void refresh() }}>
            <For each={createdRangeOptions}>{(option) => <option value={option.value}>{option.label}</option>}</For>
          </select></label>
          <Show when={createdRange() === 'custom'}>
            <label class="sort-control"><span>After</span>
              <input class="created-bound" classList={{ invalid: !createdBoundInputIsValid(customCreatedAfter()) }}
                placeholder="YYYY-MM-DD" value={customCreatedAfter()}
                onChange={(event) => { setCustomCreatedAfter(event.currentTarget.value); if (createdBoundInputIsValid(event.currentTarget.value)) void refresh() }} />
            </label>
            <label class="sort-control"><span>Before</span>
              <input class="created-bound" classList={{ invalid: !createdBoundInputIsValid(customCreatedBefore()) }}
                placeholder="YYYY-MM-DD" value={customCreatedBefore()}
                onChange={(event) => { setCustomCreatedBefore(event.currentTarget.value); if (createdBoundInputIsValid(event.currentTarget.value)) void refresh() }} />
            </label>
          </Show>
          <button class="secondary lock-toggle" aria-pressed={boardLocked()} title={boardLocked() ? 'Board is read-only; click to allow edits' : 'Board is editable; click to lock'} onClick={toggleBoardLock}>{boardLocked() ? 'Locked' : 'Editable'}</button>
          <Show when={workspaceEnabled()}>
            <button class="secondary" onClick={() => setSearchOpen(true)}>Search notes</button>
            <button onClick={() => setComposeDestination('memo')}>New memo</button>
          </Show>
          <button class="secondary" onClick={() => void refresh()}>Refresh</button>
        </div>
      </header>
      <Show when={activeScope().constraints.length > 0}>
        <div class="filter-bar" aria-label="Active notebook filters">
          <For each={activeScope().constraints}>{(constraint) =>
            <span class="filter-chip">
              <span>{constraint.kind === 'folder' ? 'Folder' : 'Tag'}: {qualifiedTagLabel(tags(), constraint.tagId)}</span>
              <button aria-label={`Remove ${qualifiedTagLabel(tags(), constraint.tagId)} filter`} onClick={() => removeScope(constraint.tagId)}>×</button>
            </span>}
          </For>
          <button ref={clearAllButton} class="secondary filter-clear" onClick={clearScope}>Clear all</button>
        </div>
      </Show>
      <Show when={message()}><div class="notes-message" role="status" aria-live="polite">{message()}<button aria-label="Dismiss message" onClick={() => setMessage('')}>×</button></div></Show>
      <Show when={error()}><div class="error-banner" role="alert">{error()} <button class="secondary" onClick={() => void refresh()}>Retry</button></div></Show>
      <Show when={loading() && notebooks().length === 0}><div class="loading-state"><span class="loader" />Loading notebooks and final board counts…</div></Show>
      <Show when={loading() && notebooks().length > 0}><div class="loading-state" role="status"><span class="loader" />Counts updating…</div></Show>
      <Show when={!loading() && !error() && notebooks().length === 0}><div ref={contentHeading} class="empty-state" tabIndex={-1}><span>◇</span><strong>No notebooks in this scope</strong><p>Select another folder or tag scope.</p></div></Show>
      <Show when={view() === 'list' && notebooks().length > 0}>
        <div class="notebook-list" aria-label="Notebooks">
          <For each={notebooks()}>{(notebook) => <button ref={(element) => registerNotebookActivator(notebook.notebookId, element)} classList={{ 'notebook-row': true, selected: selectedNotebookId() === notebook.notebookId }} onClick={(event) => void selectNotebook(notebook, event.currentTarget)}>
            <div class="notebook-row-copy">
              <strong>{notebook.title}</strong>
              <div class="notebook-row-meta"><span>{formatDate(notebook.updatedAt)}</span><Show when={normalizedNoteCount(notebook.noteCount) !== null}><span>{noteCountLabel(normalizedNoteCount(notebook.noteCount) ?? 0)}</span></Show></div>
              <Show when={normalizedPreview(notebook.firstNotePreview)}>{(value) => <span class="notebook-preview list-preview">{value()}</span>}</Show>
            </div>
            <span class={`progress-pill cat-${statusCategoryFor(notebook.progress, boardStatuses())}`}>{progressLabelFor(notebook.progress, boardStatuses())}</span>
            <FolderChips notebook={notebook} label={tagLabel} />
          </button>}</For>
        </div>
      </Show>
      <Show when={view() === 'board'}>
        <div class="notebook-board" style={{ '--board-columns': boardStatuses().length }}>
          <For each={boardStatuses()}>{(status) => {
            const column = () => boardColumnAssignments().get(status.name) ?? []
            return <section class={`board-column cat-${status.category}`} aria-label={`${statusLabel(status)} notebooks`} onDragOver={(event) => { if (!boardLocked()) event.preventDefault() }} onDrop={(event) => {
              if (boardLocked()) return
              const draggedId = event.dataTransfer?.getData('text/plain')
              finishNotebookDrag()
              const notebook = notebooks().find((item) => item.notebookId === draggedId)
              if (notebook && notebook.progress !== status.name) void moveProgress(notebook, status.name)
            }}>
              <header><strong>{statusLabel(status)}</strong><span>{column().length}</span></header>
              <div class="board-cards"><For each={column()}>{(notebook) => <article class="board-card" draggable={!boardLocked()} onDragStart={(event) => {
                if (boardLocked()) { event.preventDefault(); return }
                event.dataTransfer?.setData('text/plain', notebook.notebookId)
                setDraggingNotebookId(notebook.notebookId)
              }} onDragEnd={finishNotebookDrag}>
                <button ref={(element) => registerNotebookActivator(notebook.notebookId, element)} class="board-card-open" onClick={(event) => void selectNotebook(notebook, event.currentTarget)}>
                  <strong>{notebook.title}</strong>
                  <Show when={normalizedPreview(notebook.firstNotePreview)}>{(value) => <span class="notebook-preview board-preview">{value()}</span>}</Show>
                  <div class="board-card-meta"><span>{formatDate(notebook.updatedAt)}</span><Show when={normalizedNoteCount(notebook.noteCount) !== null}><span>{noteCountLabel(normalizedNoteCount(notebook.noteCount) ?? 0)}</span></Show></div>
                  <FolderChips notebook={notebook} label={tagLabel} />
                </button>
                <label><span class="sr-only">Move {notebook.title} to progress</span><select value={notebook.progress} disabled={boardLocked()} onChange={(event) => void moveProgress(notebook, event.currentTarget.value)}>
                  <For each={boardStatuses()}>{(option) => <option value={option.name}>{statusLabel(option)}</option>}</For>
                </select></label>
              </article>}</For></div>
            </section>
          }}</For>
        </div>
      </Show>
    </div>

    <Show when={selectedNotebook()}>{(notebook) => <aside class="note-detail" aria-label={`Notebook details for ${notebook().title}`}>
      <header><div><span class="eyebrow">NOTEBOOK</span><h2>{notebook().title}</h2><Show when={notebook().readOnly}><span class="note-readonly-badge">Read-only</span></Show></div><button class="detail-close secondary" aria-label="Close notebook details" onClick={() => closeDetail()}>×</button></header>
      <Show when={notebook().tags.some((assignment) => assignment.tag.tagId === systemMemoryNotebookKindTagId)}>
        <button class="secondary" disabled={notebookLockBusy()} aria-pressed={notebook().readOnly} onClick={() => void toggleNotebookReadOnly(notebook())}>
          {notebook().readOnly ? 'Unlock' : 'Lock'}
        </button>
      </Show>
      <Show when={workspaceEnabled()}>
        <div class="notebook-actions">
          <button class="secondary" disabled={notebook().readOnly} onClick={() => setComposeDestination('notebook')}>Add note</button>
          <Show when={props.onExpandNotebook}>
            <button class="secondary" onClick={() => props.onExpandNotebook?.(notebook().notebookId, notebook().title)}>Expand with Agent</button>
          </Show>
        </div>
      </Show>
      <dl><div><dt>Progress</dt><dd><select value={notebook().progress} disabled={boardLocked()} onChange={(event) => void moveProgress(notebook(), event.currentTarget.value)}><For each={boardStatuses()}>{(status) => <option value={status.name}>{statusLabel(status)}</option>}</For></select></dd></div><div><dt>Updated</dt><dd>{formatDate(notebook().updatedAt)}</dd></div></dl>
      <section class="assignment-group"><h3>Folder</h3>
        <Show when={folderAssignments()}>{(group) => <div class="detail-chips"><For each={group().assignments}>{(assignment) => <TagChip assignment={assignment} busy={membershipBusy()} onRemove={removeTag} label={tagLabel} />}</For></div>}</Show>
        <label><span>Add folder</span><select value="" disabled={Boolean(membershipBusy()) || availableFolders().length === 0} onChange={(event) => {
          const folder = folders().find((candidate) => candidate.tagId === event.currentTarget.value)
          if (folder) void applyExistingTag(folder)
        }}><option value="">Choose a folder…</option><For each={availableFolders()}>{(folder) => <option value={folder.tagId}>{tagLabel(folder)}</option>}</For></select></label>
      </section>
      <For each={nonFolderAssignmentGroups()}>{(group) => <section class="assignment-group"><h3>{group.label}</h3><div class="detail-chips"><For each={group.assignments}>{(assignment) => <TagChip assignment={assignment} busy={membershipBusy()} onRemove={removeTag} label={tagLabel} />}</For></div></section>}</For>
      <section class="tag-add-flow"><h3>Add tag</h3>
        <label><span>Tag class</span><select aria-label="Tag class" value={addGroupKey()} disabled={Boolean(membershipBusy())} onChange={(event) => { setAddGroupKey(event.currentTarget.value); setAddTagId('') }}>
          <option value="">Choose a tag class…</option><For each={pickerGroups()}>{(group) => <option value={group.key}>{group.label}</option>}</For>
        </select></label>
        <label><span>Existing tag</span><select aria-label="Existing tag" value={addTagId()} disabled={!selectedPickerGroup() || assignableTags().length === 0 || Boolean(membershipBusy())} onChange={(event) => setAddTagId(event.currentTarget.value)}>
          <option value="">Choose an existing tag…</option><For each={assignableTags()}>{(tag) => <option value={tag.tagId}>{tagLabel(tag)}</option>}</For>
        </select></label>
        <Show when={selectedPickerGroup() && assignableTags().length === 0}><p class="tag-picker-help">No existing tag in this group is available to assign.</p></Show>
        <button disabled={!addTagId() || Boolean(membershipBusy())} onClick={() => {
          const tag = assignableTags().find((candidate) => candidate.tagId === addTagId())
          if (tag) void applyExistingTag(tag)
        }}>Add selected tag</button>
      </section>
      <Show when={workspaceEnabled()}>
        <NoteDetailPane
          notebookId={notebook().notebookId}
          notebookTitle={notebook().title}
          notebookReadOnly={notebook().readOnly}
          noteId={activeNoteId()}
          client={client}
          workspace={workspace}
          onOpenNote={(noteId, notebookId) => void openNote(noteId, notebookId)}
          onNotebookChanged={() => void refresh()}
          onAskAgent={props.onAskAgent}
          onDirtyChange={(dirty) => { detailDirty = dirty }}
        />
      </Show>
      <Show when={!workspaceEnabled()}>
        <section class="note-preview"><h3>Read-only notes</h3><Show when={preview().length === 0 && !previewLoading()}><p>No notes in this notebook.</p></Show><For each={preview()}>{(note) => <article><div><strong>{note.title ?? `Note ${note.noteNumber}`}</strong><span>{formatDate(note.updatedAt)}</span></div><pre>{note.bodyMarkdown}</pre></article>}</For>
          <Show when={previewLoading()}><div class="loading-state"><span class="loader" />Loading notes…</div></Show>
          <Show when={previewHasMore()}><button class="secondary" disabled={previewLoading()} onClick={() => void loadPreview(notebook().notebookId, previewOffset(), true)}>Load more notes</button></Show>
        </section>
      </Show>
    </aside>}</Show>

    <Show when={workspaceEnabled() && searchOpen()}>
      <NoteSearchPopup
        client={client}
        tags={tags()}
        onOpenNote={(noteId, notebookId) => void openNote(noteId, notebookId)}
        onClose={() => setSearchOpen(false)}
      />
    </Show>
    <Show when={workspaceEnabled() && composeDestination()}>{(destination) =>
      <NoteComposePanel
        destination={destination()}
        notebookTitle={selectedNotebook()?.title}
        onSave={(bodyMarkdown) => createNote(destination(), bodyMarkdown)}
        onClose={() => setComposeDestination(undefined)}
      />}
    </Show>
  </section>
}

function TagTreeItem(props: {
  node: TagTreeNode
  level: number
  expanded: Set<string>
  activeIds: Set<string>
  focusedId?: string
  icon: string
  onToggle: (tagId: string) => void
  onSelect: (tag: NoteTag) => void
  onAdd: (tag: NoteTag) => void
  onFocus: (tagId: string) => void
  label: (tag: NoteTag) => string
}) {
  const isExpanded = () => props.expanded.has(props.node.tag.tagId)
  const isActive = () => props.activeIds.has(props.node.tag.tagId)
  const label = () => props.label(props.node.tag)
  return <div>
    <div classList={{ 'folder-row': true, selected: isActive() }} role="treeitem" aria-level={props.level} aria-expanded={props.node.children.length ? isExpanded() : undefined} aria-selected={isActive()} style={{ '--folder-level': props.level }}>
      <Show when={props.node.children.length > 0} fallback={<span class="tree-spacer" />}><button class="tree-toggle" aria-label={`${isExpanded() ? 'Collapse' : 'Expand'} ${label()}`} onClick={() => props.onToggle(props.node.tag.tagId)}>{isExpanded() ? '⌄' : '›'}</button></Show>
      <button
        class="tree-select"
        data-tag-id={props.node.tag.tagId}
        tabIndex={props.focusedId === props.node.tag.tagId ? 0 : -1}
        onFocus={() => props.onFocus(props.node.tag.tagId)}
        onKeyDown={(event) => handleTreeKeyDown(event, props)}
        onClick={() => props.onSelect(props.node.tag)}
      ><span aria-hidden="true">{props.icon}</span>{label()}</button>
      <button
        class="tree-add-filter"
        aria-label={`Add ${label()} to filter`}
        disabled={isActive()}
        onClick={(event) => {
          event.stopPropagation()
          props.onAdd(props.node.tag)
        }}
      >+</button>
    </div>
    <Show when={isExpanded()}><div role="group"><For each={props.node.children}>{(child) => <TagTreeItem {...props} node={child} level={props.level + 1} />}</For></div></Show>
  </div>
}

function KanbanSetManager(props: {
  sets: KanbanStatusSet[]
  folders: NoteTag[]
  label: (tag: NoteTag) => string
  onCreate: (name: string, statuses: Array<{ name: string; category: string }>) => Promise<void>
  onAssign: (folderId: string, setId: string | null) => Promise<void>
  onDelete: (setId: string) => Promise<void>
}) {
  const [newSetName, setNewSetName] = createSignal('')
  const [newSetStatuses, setNewSetStatuses] = createSignal('todo:pending, doing:progress, review:review, done:done')
  const [bindFolder, setBindFolder] = createSignal('')
  const [bindSetId, setBindSetId] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const parsedStatuses = () => newSetStatuses().split(',')
    .map((entry) => entry.trim()).filter(Boolean)
    .map((entry) => {
      const [name, category] = entry.split(':').map((part) => part.trim())
      return { name: name ?? '', category: category || 'progress' }
    })
    .filter((status) => status.name.length > 0)
  return <section class="kanban-set-manager" aria-label="Kanban status sets">
    <h3>Kanban status sets</h3>
    <For each={props.sets}>{(set) =>
      <div class="kanban-set-row">
        <strong>{set.name}</strong>
        <span>{set.statuses.map((status) => status.name).join(' → ')}</span>
        <Show when={!set.isSystem}>
          <button class="secondary" aria-label={`Delete status set ${set.name}`} disabled={busy()} onClick={() => {
            setBusy(true)
            void props.onDelete(set.setId).finally(() => setBusy(false))
          }}>×</button>
        </Show>
      </div>}
    </For>
    <label><span>New set name</span><input value={newSetName()} disabled={busy()} onInput={(event) => setNewSetName(event.currentTarget.value)} /></label>
    <label><span>Statuses (name:category, …)</span><input value={newSetStatuses()} disabled={busy()} onInput={(event) => setNewSetStatuses(event.currentTarget.value)} /></label>
    <button disabled={busy() || !newSetName().trim() || parsedStatuses().length === 0} onClick={() => {
      setBusy(true)
      void props.onCreate(newSetName().trim(), parsedStatuses()).finally(() => {
        setBusy(false)
        setNewSetName('')
      })
    }}>Create status set</button>
    <label><span>Bind folder</span><select value={bindFolder()} disabled={busy()} onChange={(event) => setBindFolder(event.currentTarget.value)}>
      <option value="">Choose folder…</option><For each={props.folders}>{(folder) => <option value={folder.tagId}>{props.label(folder)}</option>}</For>
    </select></label>
    <label><span>Status set</span><select value={bindSetId()} disabled={busy()} onChange={(event) => setBindSetId(event.currentTarget.value)}>
      <option value="">Default (unbind)</option><For each={props.sets.filter((set) => !set.isSystem)}>{(set) => <option value={set.setId}>{set.name}</option>}</For>
    </select></label>
    <button class="secondary" disabled={busy() || !bindFolder()} onClick={() => {
      setBusy(true)
      void props.onAssign(bindFolder(), bindSetId() || null).finally(() => setBusy(false))
    }}>Apply binding</button>
  </section>
}

function TagChip(props: {
  assignment: Notebook['tags'][number]
  busy: string
  onRemove: (tag: NoteTag) => void
  label: (tag: NoteTag) => string
}) {
  const busyKey = () => props.busy.endsWith(`:${props.assignment.tag.tagId}`)
  return <span class="folder-chip">{props.label(props.assignment.tag)}<Show when={busyKey()}><span class="sr-only">Updating</span></Show><Show when={props.assignment.deletable}><button aria-label={`Remove ${props.label(props.assignment.tag)}`} disabled={Boolean(props.busy)} onClick={() => props.onRemove(props.assignment.tag)}>×</button></Show></span>
}

function FolderChips(props: { notebook: Notebook; label: (tag: NoteTag) => string }) {
  return <span class="folder-chips"><For each={directFolderAssignments(props.notebook)}>{(tag) => <span class="folder-chip">{props.label(tag)}</span>}</For></span>
}

function focusAfterScopeEjection(
  notebooks: Notebook[],
  activators: Map<string, HTMLButtonElement>,
  clearAllButton?: HTMLButtonElement,
  contentHeading?: HTMLDivElement,
  preferredNotebookId?: string,
): void {
  queueMicrotask(() => {
    const orderedNotebooks = preferredNotebookId
      ? [
          ...notebooks.filter((notebook) => notebook.notebookId === preferredNotebookId),
          ...notebooks.filter((notebook) => notebook.notebookId !== preferredNotebookId),
        ]
      : notebooks
    for (const notebook of orderedNotebooks) {
      const activator = activators.get(notebook.notebookId)
      if (activator?.isConnected) {
        activator.focus()
        return
      }
    }
    if (clearAllButton?.isConnected) clearAllButton.focus()
    else contentHeading?.focus()
  })
}

function toggleSet(current: Set<string>, value: string): Set<string> {
  const next = new Set(current)
  if (next.has(value)) next.delete(value)
  else next.add(value)
  return next
}

function handleTreeKeyDown(
  event: KeyboardEvent & { currentTarget: HTMLButtonElement },
  props: {
    node: TagTreeNode
    level: number
    expanded: Set<string>
    onToggle: (tagId: string) => void
  },
): void {
  const tree = event.currentTarget.closest('[role="tree"]')
  if (!tree) return
  const buttons = Array.from(tree.querySelectorAll<HTMLButtonElement>('.tree-select'))
  const currentIndex = buttons.indexOf(event.currentTarget)
  const focus = (button?: HTMLButtonElement) => {
    if (!button) return
    button.focus()
  }
  switch (event.key) {
  case 'ArrowDown':
    event.preventDefault()
    focus(buttons[currentIndex + 1])
    break
  case 'ArrowUp':
    event.preventDefault()
    focus(buttons[currentIndex - 1])
    break
  case 'Home':
    event.preventDefault()
    focus(buttons[0])
    break
  case 'End':
    event.preventDefault()
    focus(buttons.at(-1))
    break
  case 'ArrowRight':
    event.preventDefault()
    if (!props.node.children.length) return
    if (!props.expanded.has(props.node.tag.tagId)) {
      props.onToggle(props.node.tag.tagId)
    } else {
      buttons[currentIndex + 1]?.focus()
    }
    break
  case 'ArrowLeft':
    event.preventDefault()
    if (props.node.children.length && props.expanded.has(props.node.tag.tagId)) {
      props.onToggle(props.node.tag.tagId)
      return
    }
    for (let index = currentIndex - 1; index >= 0; index -= 1) {
      const level = Number(buttons[index]?.closest('[role="treeitem"]')?.getAttribute('aria-level'))
      if (level < props.level) {
        focus(buttons[index])
        return
      }
    }
    break
  }
}

function normalizedPreview(value: string | null | undefined): string | undefined {
  const normalized = value?.trim()
  return normalized ? normalized : undefined
}

function normalizedNoteCount(value: number | null | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : null
}

function noteCountLabel(value: number): string {
  return `${value} ${value === 1 ? 'note' : 'notes'}`
}

function formatDate(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date)
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
