// Fold and tab state for all three panes. Persisted so a reload keeps the
// reader arranged the way it was left; every read is defensive because the
// stored value is user-editable, and unrecognized values fall back to the
// defaults.

export type LeftTab = 'files' | 'contents'
export type CenterTab = 'list' | 'notebook'
export type RightTab = 'memo' | 'info' | 'links'

export interface PaneState {
  leftOpen: boolean
  rightOpen: boolean
  leftTab: LeftTab
  centerTab: CenterTab
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
export const centerTabs: readonly CenterTab[] = ['list', 'notebook']
export const rightTabs: readonly RightTab[] = ['memo', 'info', 'links']

export const defaultPaneState: PaneState = {
  leftOpen: true,
  rightOpen: true,
  leftTab: 'files',
  centerTab: 'list',
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
    centerTab: centerTabs.includes(record.centerTab as CenterTab)
      ? record.centerTab as CenterTab
      : defaultPaneState.centerTab,
    rightTab: rightTabs.includes(record.rightTab as RightTab)
      ? record.rightTab as RightTab
      : defaultPaneState.rightTab,
    ...(typeof record.leftWidth === 'number' && Number.isFinite(record.leftWidth)
      ? { leftWidth: clampPaneWidth('left', record.leftWidth) }
      : {}),
    ...(typeof record.rightWidth === 'number' && Number.isFinite(record.rightWidth)
      ? { rightWidth: clampPaneWidth('right', record.rightWidth) }
      : {}),
  }
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

export function withCenterTab(state: PaneState, tab: CenterTab): PaneState {
  return { ...state, centerTab: tab }
}

export function withRightTab(state: PaneState, tab: RightTab): PaneState {
  return { ...state, rightTab: tab, rightOpen: true }
}
