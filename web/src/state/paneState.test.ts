import { describe, expect, test } from 'bun:test'
import {
  defaultPaneState,
  paneStateStorageKey,
  parsePaneState,
  readPaneState,
  serializePaneState,
  withLeftTab,
  withRightTab,
  writePaneState,
  type PaneState,
  type PaneStateStorage,
} from './paneState'

function storage(initial?: string): PaneStateStorage & { values: Map<string, string> } {
  const values = new Map<string, string>()
  if (initial !== undefined) values.set(paneStateStorageKey, initial)
  return {
    values,
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => { values.set(key, value) },
  }
}

const folded: PaneState = { leftOpen: false, rightOpen: true, leftTab: 'contents', rightTab: 'chat' }

describe('pane state persistence', () => {
  test('round-trips fold and tab selection', () => {
    const store = storage()
    writePaneState(folded, store)
    expect(readPaneState(store)).toEqual(folded)
  })

  test('defaults when nothing was stored', () => {
    expect(readPaneState(storage())).toEqual(defaultPaneState)
    expect(readPaneState(undefined)).toEqual(defaultPaneState)
  })

  test('ignores malformed and partial stored values field by field', () => {
    expect(parsePaneState('not json')).toEqual(defaultPaneState)
    expect(parsePaneState('null')).toEqual(defaultPaneState)
    expect(parsePaneState('[]')).toEqual(defaultPaneState)
    expect(parsePaneState(serializePaneState(folded).replace('"contents"', '"removed-tab"')))
      .toEqual({ ...folded, leftTab: defaultPaneState.leftTab })
    expect(parsePaneState('{"leftOpen":false}'))
      .toEqual({ ...defaultPaneState, leftOpen: false })
    expect(parsePaneState('{"rightOpen":"yes"}')).toEqual(defaultPaneState)
  })

  test('a storage that throws never breaks the layout', () => {
    const throwing: PaneStateStorage = {
      getItem: () => { throw new Error('blocked') },
      setItem: () => { throw new Error('blocked') },
    }
    expect(readPaneState(throwing)).toEqual(defaultPaneState)
    expect(() => writePaneState(folded, throwing)).not.toThrow()
  })
})

describe('tab selection', () => {
  test('picking a tab opens its pane', () => {
    expect(withLeftTab({ ...defaultPaneState, leftOpen: false }, 'contents'))
      .toEqual({ ...defaultPaneState, leftOpen: true, leftTab: 'contents' })
    expect(withRightTab({ ...defaultPaneState, rightOpen: false }, 'chat'))
      .toEqual({ ...defaultPaneState, rightOpen: true, rightTab: 'chat' })
  })

  test('the other pane is untouched', () => {
    expect(withLeftTab(folded, 'files').rightTab).toBe('chat')
    expect(withRightTab(folded, 'info').leftOpen).toBe(false)
  })
})
