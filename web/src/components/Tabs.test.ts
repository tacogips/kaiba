import { describe, expect, test } from 'bun:test'
import { nextEnabledTabIndex, type TabDescriptor } from './Tabs'

type Tab = 'files' | 'contents' | 'info'

const tabs: readonly TabDescriptor<Tab>[] = [
  { value: 'files', label: 'Files' },
  { value: 'contents', label: 'Contents', disabled: true },
  { value: 'info', label: 'Info' },
]

describe('tab keyboard navigation', () => {
  test('skips disabled tabs in both directions', () => {
    expect(nextEnabledTabIndex(tabs, 0, 'ArrowRight')).toBe(2)
    expect(nextEnabledTabIndex(tabs, 2, 'ArrowLeft')).toBe(0)
  })

  test('home and end choose enabled tabs', () => {
    expect(nextEnabledTabIndex(tabs, 2, 'Home')).toBe(0)
    expect(nextEnabledTabIndex(tabs, 0, 'End')).toBe(2)
  })

  test('ignores unrelated keys and an entirely disabled tab list', () => {
    expect(nextEnabledTabIndex(tabs, 0, 'Enter')).toBeUndefined()
    expect(nextEnabledTabIndex([{ ...tabs[1]! }], 0, 'ArrowRight')).toBeUndefined()
  })
})
