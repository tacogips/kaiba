import { describe, expect, test } from 'bun:test'
import { createdBoundInputIsValid, createdBounds } from './createdFilter'

describe('createdBounds', () => {
  const now = new Date('2026-07-31T12:00:00.000Z')

  test('any range has no bounds', () => {
    expect(createdBounds('any', '', '', now)).toEqual({})
  })

  test('today starts at local midnight', () => {
    const bounds = createdBounds('today', '', '', now)
    expect(bounds.createdBefore).toBeUndefined()
    const start = new Date(bounds.createdAfter!)
    expect(start.getHours()).toBe(0)
    expect(start.getMinutes()).toBe(0)
    expect(start.getTime()).toBeLessThanOrEqual(now.getTime())
  })

  test('rolling windows subtract whole days', () => {
    expect(createdBounds('last7Days', '', '', now).createdAfter)
      .toBe(new Date(now.getTime() - 7 * 86_400_000).toISOString())
    expect(createdBounds('last30Days', '', '', now).createdAfter)
      .toBe(new Date(now.getTime() - 30 * 86_400_000).toISOString())
  })

  test('custom passes trimmed non-empty bounds only', () => {
    expect(createdBounds('custom', ' 2026-01-01 ', '', now)).toEqual({ createdAfter: '2026-01-01' })
    expect(createdBounds('custom', '', '2026-06-01T00:00:00Z', now))
      .toEqual({ createdBefore: '2026-06-01T00:00:00Z' })
  })
})

describe('createdBoundInputIsValid', () => {
  test('accepts empty, date-only and ISO timestamps', () => {
    expect(createdBoundInputIsValid('')).toBe(true)
    expect(createdBoundInputIsValid('2026-07-31')).toBe(true)
    expect(createdBoundInputIsValid('2026-07-31T09:30:00Z')).toBe(true)
  })

  test('rejects non-dates', () => {
    expect(createdBoundInputIsValid('yesterday-ish')).toBe(false)
  })
})
