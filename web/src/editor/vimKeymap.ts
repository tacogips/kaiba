// The user's Vim keymap as stored in the web settings. No stored keymap means
// the engine's plain built-in bindings (no mappings, no hints, no hop), the
// same as vactr before a keymap is applied.

import { compileKeymap, type CompiledKeymap, type KeymapIssue } from './vim/keymap-schema'
import { KEYMAP_PRESETS } from './vim/presets'

export { KEYMAP_PRESETS } from './vim/presets'
export type { KeymapIssue } from './vim/keymap-schema'

export function compileUserKeymap(text: string | undefined): { keymap: CompiledKeymap | null; issues: KeymapIssue[] } {
  if (!text?.trim()) return { keymap: null, issues: [] }
  return compileKeymap(text)
}

/** The text shown in the keymap editor when nothing custom is stored. */
export const defaultKeymapText = KEYMAP_PRESETS[0]!.text
