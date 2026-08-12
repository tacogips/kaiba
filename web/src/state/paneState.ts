// Fold and tab state for the two side panes. Persisted so a reload keeps the
// reader arranged the way it was left; every read is defensive because the
// stored value is user-editable and may predate a tab rename.

export type LeftTab = 'files' | 'contents'
export type RightTab = 'memo' | 'info' | 'links'

export interface PaneState {
  leftOpen: boolean
  rightOpen: boolean
  leftTab: LeftTab
  rightTab: RightTab
  /** Drag-resized pane widths in px; undefined keeps the stylesheet default. */
  leftWidth?: number
  rightWidth?: number
}

export const paneWidthBounds = {
  left: { minimum: 170, maximum: 700 },
  right: { minimum: 240, maximum: 1100 },
} as const

export function clampPaneWidth(side: 'left' | 'right', width: number): number {
  const bounds = paneWidthBounds[side]
  return Math.round(Math.min(bounds.maximum, Math.max(bounds.minimum, width)))
}

export const paneStateStorageKey = 'kaiba-chatbook-panes'
export const leftTabs: readonly LeftTab[] = ['files', 'contents']
export const rightTabs: readonly RightTab[] = ['memo', 'info', 'links']

export const defaultPaneState: PaneState = {
  leftOpen: true,
  rightOpen: true,
  leftTab: 'files',
  rightTab: 'memo',
}

export interface PaneStateStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

export function parsePaneState(raw: string | null): PaneState {
  if (!raw) return defaultPaneState
  let value: unknown
  try {
    value = JSON.parse(raw)
  } catch {
    return defaultPaneState
  }
  if (typeof value !== 'object' || value === null) return defaultPaneState
  const record = value as Record<string, unknown>
  return {
    leftOpen: typeof record.leftOpen === 'boolean' ? record.leftOpen : defaultPaneState.leftOpen,
    rightOpen: typeof record.rightOpen === 'boolean' ? record.rightOpen : defaultPaneState.rightOpen,
    leftTab: leftTabs.includes(record.leftTab as LeftTab)
      ? record.leftTab as LeftTab
      : defaultPaneState.leftTab,
    rightTab: normalizeRightTab(record.rightTab),
    ...(typeof record.leftWidth === 'number' && Number.isFinite(record.leftWidth)
      ? { leftWidth: clampPaneWidth('left', record.leftWidth) }
      : {}),
    ...(typeof record.rightWidth === 'number' && Number.isFinite(record.rightWidth)
      ? { rightWidth: clampPaneWidth('right', record.rightWidth) }
      : {}),
  }
}

/** Stored values from before memos and chat merged ("memos", "chat") land on
 * the unified memo tab rather than resetting the whole pane state. */
function normalizeRightTab(raw: unknown): RightTab {
  if (rightTabs.includes(raw as RightTab)) return raw as RightTab
  if (raw === 'memos' || raw === 'chat') return 'memo'
  return defaultPaneState.rightTab
}

export function serializePaneState(state: PaneState): string {
  return JSON.stringify(state)
}

export function readPaneState(storage?: PaneStateStorage): PaneState {
  if (!storage) return defaultPaneState
  try {
    return parsePaneState(storage.getItem(paneStateStorageKey))
  } catch {
    // A storage-disabled browser still gets a usable layout.
    return defaultPaneState
  }
}

export function writePaneState(state: PaneState, storage?: PaneStateStorage): void {
  if (!storage) return
  try {
    storage.setItem(paneStateStorageKey, serializePaneState(state))
  } catch {
    // Persistence is best-effort; the layout still applies to this session.
  }
}

export function browserPaneStorage(): PaneStateStorage | undefined {
  return typeof localStorage === 'undefined' ? undefined : localStorage
}

/** Opening a pane by picking one of its tabs is a single state change, so a
 * click on a collapsed pane's rail button lands on a visible tab. */
export function withLeftTab(state: PaneState, tab: LeftTab): PaneState {
  return { ...state, leftTab: tab, leftOpen: true }
}

export function withRightTab(state: PaneState, tab: RightTab): PaneState {
  return { ...state, rightTab: tab, rightOpen: true }
}
