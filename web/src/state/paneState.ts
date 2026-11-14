// Fold and tab state for the two side panes. Persisted so a reload keeps the
// reader arranged the way it was left; every read is defensive because the
// stored value is user-editable and may predate a tab rename.

export type LeftTab = 'files' | 'contents'
export type RightTab = 'memos' | 'info' | 'links' | 'chat'

export interface PaneState {
  leftOpen: boolean
  rightOpen: boolean
  leftTab: LeftTab
  rightTab: RightTab
}

export const paneStateStorageKey = 'kaiba-chatbook-panes'
export const leftTabs: readonly LeftTab[] = ['files', 'contents']
export const rightTabs: readonly RightTab[] = ['memos', 'info', 'links', 'chat']

export const defaultPaneState: PaneState = {
  leftOpen: true,
  rightOpen: true,
  leftTab: 'files',
  rightTab: 'memos',
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
    rightTab: rightTabs.includes(record.rightTab as RightTab)
      ? record.rightTab as RightTab
      : defaultPaneState.rightTab,
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

export function withRightTab(state: PaneState, tab: RightTab): PaneState {
  return { ...state, rightTab: tab, rightOpen: true }
}
