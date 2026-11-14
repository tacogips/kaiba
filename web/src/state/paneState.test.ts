import { describe, expect, test } from 'bun:test'
import {
  defaultPaneState,
  paneStateStorageKey,
  parsePaneState,
  readPaneState,
  serializePaneState,
  withCenterTab,
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

const folded: PaneState = {
  leftOpen: false,
  rightOpen: true,
  leftTab: 'contents',
  centerTab: 'notebook',
  rightTab: 'links',
}

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

  test('pre-merge tab names land on the unified memo tab', () => {
    expect(parsePaneState('{"rightTab":"memos"}').rightTab).toBe('memo')
    expect(parsePaneState('{"rightTab":"chat"}').rightTab).toBe('memo')
  })

  test('drag-resized pane widths persist, clamp, and ignore junk', () => {
    expect(parsePaneState('{"leftWidth":300,"rightWidth":500}'))
      .toEqual({ ...defaultPaneState, leftWidth: 300, rightWidth: 500 })
    expect(parsePaneState('{"leftWidth":5,"rightWidth":99999}'))
      .toEqual({ ...defaultPaneState, leftWidth: 170, rightWidth: 1100 })
    expect(parsePaneState('{"leftWidth":"wide"}')).toEqual(defaultPaneState)
    const resized: PaneState = { ...defaultPaneState, leftWidth: 320 }
    expect(parsePaneState(serializePaneState(resized))).toEqual(resized)
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
    expect(withRightTab({ ...defaultPaneState, rightOpen: false }, 'links'))
      .toEqual({ ...defaultPaneState, rightOpen: true, rightTab: 'links' })
    expect(withCenterTab(defaultPaneState, 'notebook'))
      .toEqual({ ...defaultPaneState, centerTab: 'notebook' })
  })

  test('the other pane is untouched', () => {
    expect(withLeftTab(folded, 'files').rightTab).toBe('links')
    expect(withRightTab(folded, 'info').leftOpen).toBe(false)
    expect(withCenterTab(folded, 'list').leftTab).toBe('contents')
  })
})
