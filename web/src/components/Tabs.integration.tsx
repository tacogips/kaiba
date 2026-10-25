import { describe, expect, test } from 'vitest'
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

test('fits tabs without scrolling and expands the remaining tabs through the ellipsis button', async () => {
  const { render } = await import('solid-js/web')
  const { createSignal } = await import('solid-js')
  const { Tabs } = await import('./Tabs')
  const original = globalThis.ResizeObserver
  const callbacks: ResizeObserverCallback[] = []
  globalThis.ResizeObserver = class {
    constructor(callback: ResizeObserverCallback) { callbacks.push(callback) }
    observe() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver
  const host = document.createElement('div'); host.className = 'chatbook'; document.body.append(host)
  const [active, setActive] = createSignal('ai')
  const dispose = render(() => <Tabs label="Details" tabs={[
    { value: 'ai', label: 'AI' }, { value: 'tags', label: 'Tags' }, { value: 'analysis', label: 'Analysis' }, { value: 'links', label: 'Backlinks' },
  ]} active={active()} idPrefix="overflow-test" onSelect={setActive} />, host)
  try {
    const root = host.querySelector<HTMLElement>('.pane-tabs-overflow')!
    let width = 220
    Object.defineProperty(root, 'clientWidth', { get: () => width })
    host.querySelectorAll<HTMLElement>('.pane-tabs-measure > span').forEach((element) => {
      element.getBoundingClientRect = () => ({ width: 80 }) as DOMRect
    })
    const measure = () => callbacks.forEach((callback) => callback([], {} as ResizeObserver))
    measure(); await new Promise((resolve) => setTimeout(resolve, 0))
    const visible = () => [...host.querySelectorAll<HTMLButtonElement>('[role="tab"]')].filter((button) => !button.hidden).map((button) => button.textContent)
    expect(visible()).toEqual(['AI', 'Tags'])
    const more = host.querySelector<HTMLButtonElement>('[aria-label="More tabs"]')!
    expect(more.getAttribute('aria-hidden')).toBe('false'); more.click()
    const menu = document.querySelector('[role="menu"][aria-label="More tabs"]')!
    expect(menu.textContent).toContain('Analysis'); expect(menu.textContent).toContain('Backlinks')
    ;[...menu.querySelectorAll<HTMLButtonElement>('button')].find((button) => button.textContent === 'Backlinks')!.click()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(active()).toBe('links'); expect(visible()).toEqual(['AI', 'Backlinks'])
    expect(document.querySelector('[role="menu"][aria-label="More tabs"]')).toBeNull()
    width = 400; measure(); expect(visible()).toHaveLength(4)
    expect(more.getAttribute('aria-hidden')).toBe('true')
  } finally { dispose(); host.remove(); globalThis.ResizeObserver = original }
})
