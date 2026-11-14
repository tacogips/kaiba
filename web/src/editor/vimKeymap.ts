// The user's Vim keymap as stored in the web settings. No stored keymap means
// the Default preset: no mappings or hop, but which-key hints for the `g`,
// `z` and `m` prefixes.

import { compileKeymap, type CompiledKeymap, type KeymapIssue } from './vim/keymap-schema'
import { KEYMAP_PRESETS } from './vim/presets'

export { KEYMAP_PRESETS } from './vim/presets'
export type { KeymapIssue } from './vim/keymap-schema'

export function compileUserKeymap(text: string | undefined): { keymap: CompiledKeymap | null; issues: KeymapIssue[] } {
  return compileKeymap(text?.trim() ? text : defaultKeymapText)
}

/** The text shown in the keymap editor when nothing custom is stored. */
export const defaultKeymapText = KEYMAP_PRESETS[0]!.text
