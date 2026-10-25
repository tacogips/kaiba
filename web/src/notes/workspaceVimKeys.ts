import { parseNotation } from '../editor/vim/notation'

/** Where a workspace binding applies: `any` also fires inside text fields
 * (Ctrl-W chords), `normal` also fires in a Vim editor's normal mode, and
 * `reader` only outside text fields. */
export type WorkspaceVimContext = 'any' | 'normal' | 'reader'

export const workspaceVimActions = {
  write: { keys: 'i', desc: 'Write at the current note', context: 'reader' },
  left: { keys: '<C-w>h', desc: 'Focus library', context: 'any' },
  right: { keys: '<C-w>l', desc: 'Focus details', context: 'any' },
  bottom: { keys: '<C-w>j', desc: 'Focus AI', context: 'any' },
  reader: { keys: '<C-w>k', desc: 'Focus reader', context: 'any' },
  next: { keys: '<C-w>w', desc: 'Next pane', context: 'any' },
  writing: { keys: '<Space>w', desc: 'Toggle Writing / Preview', context: 'normal' },
  agent: { keys: '<Space>a', desc: 'Open / close AI', context: 'normal' },
  library: { keys: '<Space>e', desc: 'Toggle library', context: 'normal' },
  details: { keys: '<Space>d', desc: 'Toggle details', context: 'normal' },
  search: { keys: '<Space>f', desc: 'Quick switcher', context: 'normal' },
  gotoPage: { keys: 'gp', desc: 'Go to page… (with a count: that page)', context: 'reader' },
  firstPage: { keys: 'gg', desc: 'First page (with a count: that page)', context: 'reader' },
  lastPage: { keys: 'G', desc: 'Last page (with a count: that page)', context: 'reader' },
} as const satisfies Record<string, { keys: string; desc: string; context: WorkspaceVimContext }>

export type WorkspaceVimAction = keyof typeof workspaceVimActions

export const defaultWorkspaceVimKeys = Object.fromEntries(
  Object.entries(workspaceVimActions).map(([action, { keys }]) => [action, keys]),
) as Record<WorkspaceVimAction, string>

export type WorkspaceVimKeys = Partial<Record<WorkspaceVimAction, string>>
export function workspaceVimKeysIssue(overrides: WorkspaceVimKeys): string | undefined {
  const entries = Object.entries({ ...defaultWorkspaceVimKeys, ...overrides }).map(([action, text]) => ({ action, parsed: parseNotation(text, null) }))
  for (const entry of entries) if ('error' in entry.parsed || !entry.parsed.keys.length) return `Invalid keybinding for ${entry.action}.`
  for (let a = 0; a < entries.length; a++) for (let b = a + 1; b < entries.length; b++) {
    const first = entries[a]!, second = entries[b]!
    if (!('keys' in first.parsed) || !('keys' in second.parsed)) continue
    const firstKeys = first.parsed.keys, secondKeys = second.parsed.keys
    const count = Math.min(firstKeys.length, secondKeys.length)
    if (firstKeys.slice(0, count).every((key, index) => secondKeys[index] === key)) return `Keybindings for ${first.action} and ${second.action} overlap. Choose distinct sequences.`
  }
  return undefined
}
export function parseWorkspaceVimKeys(value: unknown): WorkspaceVimKeys {
  if (!value || typeof value !== 'object') return {}
  const keys: WorkspaceVimKeys = {}
  for (const name of Object.keys(defaultWorkspaceVimKeys) as WorkspaceVimAction[]) {
    const text = (value as Record<string, unknown>)[name]
    if (typeof text !== 'string' || text.length > 80) continue
    const parsed = parseNotation(text, null)
    if ('keys' in parsed && parsed.keys.length > 0 && parsed.keys.length <= 4) keys[name] = text
  }
  return keys
}

/** The effective bindings: defaults with valid overrides applied. */
export function workspaceVimBindings(overrides: WorkspaceVimKeys | undefined): { action: WorkspaceVimAction; keys: string[]; desc: string; context: WorkspaceVimContext }[] {
  return (Object.keys(workspaceVimActions) as WorkspaceVimAction[]).flatMap((action) => {
    const parsed = parseNotation(overrides?.[action] ?? defaultWorkspaceVimKeys[action], null)
    const { desc, context } = workspaceVimActions[action]
    return 'keys' in parsed && parsed.keys.length ? [{ action, keys: parsed.keys, desc, context }] : []
  })
}
