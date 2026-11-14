import { describe, expect, test } from 'bun:test'
import {
  clampFontScale,
  defaultWebSettings,
  parseWebSettings,
  serializeWebSettings,
  vimModeEnabled,
} from './settings'

describe('web settings parsing', () => {
  test('round-trips through serialize and parse', () => {
    expect(parseWebSettings(serializeWebSettings({ fontScale: 1.3 }))).toEqual({ fontScale: 1.3 })
  })

  test('preserves a selected agent model and accepts a document without one', () => {
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

  test('keeps Vim mode on unless it is explicitly turned off', () => {
    expect(vimModeEnabled(defaultWebSettings)).toBe(true)
    expect(vimModeEnabled(parseWebSettings('{"fontScale":1.1,"vimMode":true}'))).toBe(true)
    expect(vimModeEnabled(parseWebSettings('{"vimMode":"no"}'))).toBe(true)
    const off = parseWebSettings(serializeWebSettings({ fontScale: 1.1, vimMode: false }))
    expect(off).toEqual({ fontScale: 1.1, vimMode: false })
    expect(vimModeEnabled(off)).toBe(false)
    expect(serializeWebSettings({ fontScale: 1.1, vimMode: true })).toBe('{"fontScale":1.1}')
  })

  test('round-trips a custom Vim keymap verbatim and drops a blank one', () => {
    const vimKeymap = '{\n  "version": 1,\n  "maps": { "i": [{ "lhs": "jk", "rhs": "<Esc>" }] }\n}'
    expect(parseWebSettings(serializeWebSettings({ fontScale: 1.1, vimKeymap })).vimKeymap).toBe(vimKeymap)
    expect(parseWebSettings(serializeWebSettings({ fontScale: 1.1, vimKeymap: '  ' }))).toEqual({ fontScale: 1.1 })
    expect(parseWebSettings('{"vimKeymap":42}').vimKeymap).toBeUndefined()
  })
})

test('persists validated workspace Vim keys', () => {
  expect(parseWebSettings(serializeWebSettings({ fontScale: 1.15, workspaceVimKeys: { write: 'e', left: '<C-w>h' } })).workspaceVimKeys)
    .toEqual({ write: 'e', left: '<C-w>h' })
  expect(parseWebSettings('{"workspaceVimKeys":{"write":"<unknown>","left":"<C-w>h","unrelated":"x"}}').workspaceVimKeys)
    .toEqual({ left: '<C-w>h' })
})

test('workspace key validation rejects duplicate and prefix-shadowing sequences', async () => {
  const { workspaceVimKeysIssue } = await import('./workspaceVimKeys')
  expect(workspaceVimKeysIssue({ write: 'e' })).toBeUndefined()
  expect(workspaceVimKeysIssue({ reader: '<C-w>' })).toContain('overlap')
  expect(workspaceVimKeysIssue({ reader: '<C-w>h' })).toContain('overlap')
})
