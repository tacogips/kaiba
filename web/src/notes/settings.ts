// Web app settings persisted in the kaiba store's sqlite (`app_settings`
// table, key "web") so preferences follow the store, not one browser. Parsing
// is defensive: the stored document is user-visible JSON and may predate or
// outlive this shape.

export interface WebAppSettings {
  /** Multiplier applied to every font size (the `--fs` CSS variable). */
  fontScale: number
  /** Last model selected for agent turns; server validation remains authoritative. */
  agentModel?: string
}

export const webSettingsKey = 'web'

/** Larger-than-1 default: the app reads bigger out of the box. */
export const defaultWebSettings: WebAppSettings = { fontScale: 1.15 }

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
  }
}

export function serializeWebSettings(settings: WebAppSettings): string {
  return JSON.stringify({
    fontScale: clampFontScale(settings.fontScale),
    ...(settings.agentModel?.trim() ? { agentModel: settings.agentModel.trim() } : {}),
  })
}
