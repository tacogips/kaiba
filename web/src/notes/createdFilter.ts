// Created-range filter for the notebook list, mirroring the native
// RielaNoteListFilter.CreatedRange semantics (today / rolling windows are
// resolved client-side into createdAfter bounds; custom passes both bounds).

export type CreatedRange = 'any' | 'today' | 'last7Days' | 'last30Days' | 'custom'

export const createdRangeOptions: Array<{ value: CreatedRange; label: string }> = [
  { value: 'any', label: 'Any' },
  { value: 'today', label: 'Today' },
  { value: 'last7Days', label: '7 days' },
  { value: 'last30Days', label: '30 days' },
  { value: 'custom', label: 'Custom' },
]

export interface CreatedBounds {
  createdAfter?: string
  createdBefore?: string
}

/** Empty is valid (no bound); otherwise YYYY-MM-DD or a parseable ISO-8601
 * timestamp, mirroring `rielaNoteCreatedBoundInputIsValid`. */
export function createdBoundInputIsValid(rawValue: string): boolean {
  const trimmed = rawValue.trim()
  if (trimmed.length === 0) return true
  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return !Number.isNaN(Date.parse(trimmed))
  return !Number.isNaN(Date.parse(trimmed))
}

export function createdBounds(
  range: CreatedRange,
  customAfter: string,
  customBefore: string,
  now: Date = new Date(),
): CreatedBounds {
  switch (range) {
    case 'any':
      return {}
    case 'custom': {
      const after = customAfter.trim()
      const before = customBefore.trim()
      return {
        ...(after ? { createdAfter: after } : {}),
        ...(before ? { createdBefore: before } : {}),
      }
    }
    case 'today': {
      const start = new Date(now)
      start.setHours(0, 0, 0, 0)
      return { createdAfter: start.toISOString() }
    }
    case 'last7Days':
      return { createdAfter: new Date(now.getTime() - 7 * 86_400_000).toISOString() }
    case 'last30Days':
      return { createdAfter: new Date(now.getTime() - 30 * 86_400_000).toISOString() }
  }
}
