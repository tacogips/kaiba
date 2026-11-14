// Web app settings persisted in the kaiba store's sqlite (`app_settings`
// table, key "web") so preferences follow the store, not one browser. Parsing
// is defensive: the stored document is user-visible JSON and may predate or
// outlive this shape.

import { parseAnalysisTemplates, type AnalysisTemplate } from './analysisTemplates'
import { parseWorkspaceVimKeys, type WorkspaceVimKeys } from './workspaceVimKeys'

export type PDFTextMode = 'prefer-pdf-text' | 'ocr-only'

export interface WebAppSettings {
  /** Multiplier applied to every font size (the `--fs` CSS variable). */
  fontScale: number
  /** Last model selected for agent turns; server validation remains authoritative. */
  agentModel?: string
  agentProvider?: string
  analysisTemplates?: AnalysisTemplate[]
  pdfTextMode?: PDFTextMode
  /** Vim keybindings in the Markdown editors. Absent means on: Vim is the
   * default editing mode, and only an explicit `false` turns it off. */
  vimMode?: boolean
  /** Custom Vim keymap JSON (see web/src/editor/vim/keymap-schema.ts); absent
   * means the built-in bindings. Kept as text so the user's layout survives. */
  vimKeymap?: string
  workspaceVimKeys?: WorkspaceVimKeys
}

export const webSettingsKey = 'web'

/** Larger-than-1 default: the app reads bigger out of the box. */
export const defaultWebSettings: WebAppSettings = { fontScale: 1.15 }

export function vimModeEnabled(settings: Pick<WebAppSettings, 'vimMode'>): boolean {
  return settings.vimMode !== false
}

export const fontScaleBounds = { minimum: 0.8, maximum: 1.8 } as const

export function clampFontScale(value: number): number {
  if (!Number.isFinite(value)) return defaultWebSettings.fontScale
  const bounded = Math.min(fontScaleBounds.maximum, Math.max(fontScaleBounds.minimum, value))
  return Math.round(bounded * 100) / 100
}

export function parseWebSettings(json: string | null | undefined): WebAppSettings {
  if (!json) return defaultWebSettings
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return defaultWebSettings
  }
  if (typeof value !== 'object' || value === null) return defaultWebSettings
  const record = value as Record<string, unknown>
  const agentModel = typeof record.agentModel === 'string' && record.agentModel.trim()
    ? record.agentModel.trim()
    : undefined
  return {
    fontScale: typeof record.fontScale === 'number'
      ? clampFontScale(record.fontScale)
      : defaultWebSettings.fontScale,
    ...(agentModel ? { agentModel } : {}),
    ...(['prefer-pdf-text', 'ocr-only'].includes(String(record.pdfTextMode)) ? { pdfTextMode: record.pdfTextMode as PDFTextMode } : {}),
    ...(parseAnalysisTemplates(record.analysisTemplates).length ? { analysisTemplates: parseAnalysisTemplates(record.analysisTemplates) } : {}),
    ...(typeof record.agentProvider === 'string' && record.agentProvider.trim() ? { agentProvider: record.agentProvider.trim() } : {}),
    ...(record.vimMode === false ? { vimMode: false } : {}),
    ...(typeof record.vimKeymap === 'string' && record.vimKeymap.trim() ? { vimKeymap: record.vimKeymap } : {}),
    ...(record.workspaceVimKeys ? { workspaceVimKeys: parseWorkspaceVimKeys(record.workspaceVimKeys) } : {}),
  }
}

export function serializeWebSettings(settings: WebAppSettings): string {
  return JSON.stringify({
    fontScale: clampFontScale(settings.fontScale),
    ...(settings.pdfTextMode ? { pdfTextMode: settings.pdfTextMode } : {}),
    ...(settings.analysisTemplates?.length ? { analysisTemplates: parseAnalysisTemplates(settings.analysisTemplates) } : {}),
    ...(settings.agentProvider?.trim() ? { agentProvider: settings.agentProvider.trim() } : {}),
    ...(settings.agentModel?.trim() ? { agentModel: settings.agentModel.trim() } : {}),
    ...(settings.vimMode === false ? { vimMode: false } : {}),
    ...(settings.vimKeymap?.trim() ? { vimKeymap: settings.vimKeymap } : {}),
    ...(settings.workspaceVimKeys ? { workspaceVimKeys: parseWorkspaceVimKeys(settings.workspaceVimKeys) } : {}),
  })
}
