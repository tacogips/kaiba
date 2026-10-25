import { parseNotation } from '../editor/vim/notation'

export const defaultWorkspaceVimKeys = {
  write: 'i', left: '<C-w>h', right: '<C-w>l', bottom: '<C-w>j', reader: '<C-w>k', next: '<C-w>w',
}
export type WorkspaceVimKeys = Partial<Record<keyof typeof defaultWorkspaceVimKeys, string>>
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
  for (const name of Object.keys(defaultWorkspaceVimKeys) as (keyof WorkspaceVimKeys)[]) {
    const text = (value as Record<string, unknown>)[name]
    if (typeof text !== 'string' || text.length > 80) continue
    const parsed = parseNotation(text, null)
    if ('keys' in parsed && parsed.keys.length > 0 && parsed.keys.length <= 4) keys[name] = text
  }
  return keys
}
