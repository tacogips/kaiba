import { describe, expect, test } from 'bun:test'
import {
  clampFontScale,
  defaultWebSettings,
  parseWebSettings,
  serializeWebSettings,
} from './settings'

describe('web settings parsing', () => {
  test('round-trips through serialize and parse', () => {
    expect(parseWebSettings(serializeWebSettings({ fontScale: 1.3 }))).toEqual({ fontScale: 1.3 })
  })

  test('preserves a selected agent model while accepting older setting documents', () => {
    expect(parseWebSettings(serializeWebSettings({ fontScale: 1.3, agentModel: 'openai/gpt-5-mini' })))
      .toEqual({ fontScale: 1.3, agentModel: 'openai/gpt-5-mini' })
    expect(parseWebSettings('{"fontScale":1.1}').agentModel).toBeUndefined()
  })

  test('defaults when unset, malformed, or the wrong shape', () => {
    expect(parseWebSettings(null)).toEqual(defaultWebSettings)
    expect(parseWebSettings('')).toEqual(defaultWebSettings)
    expect(parseWebSettings('not json')).toEqual(defaultWebSettings)
    expect(parseWebSettings('[]')).toEqual(defaultWebSettings)
    expect(parseWebSettings('{"fontScale":"big"}')).toEqual(defaultWebSettings)
  })

  test('clamps out-of-range scales instead of applying them', () => {
    expect(parseWebSettings('{"fontScale":99}').fontScale).toBe(1.8)
    expect(parseWebSettings('{"fontScale":0.01}').fontScale).toBe(0.8)
    expect(clampFontScale(Number.NaN)).toBe(defaultWebSettings.fontScale)
  })
})
