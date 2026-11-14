import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'
import { WorkspaceIcon } from './WorkspaceIcon'
import { usePopoverDismissal } from './usePopoverDismissal'
import './tabs.css'

// One accessible tab strip for both side panes: roving tab stop, arrow-key
// movement, and the `tablist`/`tab`/`tabpanel` wiring the panes rely on.

export interface TabDescriptor<Value extends string> {
  value: Value
  label: string
  disabled?: boolean
  title?: string
}

export function Tabs<Value extends string>(props: {
  label: string
  tabs: readonly TabDescriptor<Value>[]
  active: Value
  idPrefix: string
  onSelect: (value: Value) => void
}): JSX.Element {
  let root!: HTMLDivElement
  let strip!: HTMLDivElement
  let measuring!: HTMLDivElement
  let more!: HTMLButtonElement
  let menu: HTMLDivElement | undefined
  const [visible, setVisible] = createSignal<readonly Value[]>(props.tabs.map((tab) => tab.value))
  const [open, setOpen] = createSignal(false)
  const [position, setPosition] = createSignal({ top: 0, right: 0 })
  const overflow = createMemo(() => props.tabs.filter((tab) => !visible().includes(tab.value)))
  const locateMenu = () => {
    const box = more.getBoundingClientRect()
    setPosition({ top: box.bottom + 4, right: Math.max(8, window.innerWidth - box.right) })
  }
  const measure = () => {
    const width = root.clientWidth
    if (!width) return
    const widths = [...measuring.children].map((element) => element.getBoundingClientRect().width)
    const gap = Number.parseFloat(getComputedStyle(strip).gap) || 0
    const total = widths.reduce((sum, value) => sum + value, 0) + gap * Math.max(0, widths.length - 1)
    if (total <= width) { setVisible(props.tabs.map((tab) => tab.value)); setOpen(false); return }
    const budget = Math.max(0, width - (more.getBoundingClientRect().width || 28) - gap)
    const indices: number[] = []
    let used = 0
    for (let index = 0; index < props.tabs.length; index++) {
      const cost = widths[index]! + (indices.length ? gap : 0)
      if (used + cost > budget) break
      indices.push(index); used += cost
    }
    const active = props.tabs.findIndex((tab) => tab.value === props.active)
    if (active >= 0 && !indices.includes(active)) {
      while (indices.length && used + widths[active]! + gap > budget) {
        const removed = indices.pop()!; used -= widths[removed]! + (indices.length ? gap : 0)
      }
      indices.push(active)
    }
    setVisible(indices.sort((a, b) => a - b).map((index) => props.tabs[index]!.value))
    if (open()) locateMenu()
  }
  createEffect(() => { void props.active; void props.tabs; queueMicrotask(measure) })
  onMount(() => {
    const observer = new ResizeObserver(measure)
    observer.observe(root); observer.observe(measuring)
    window.addEventListener('resize', measure)
    measure()
    onCleanup(() => { observer.disconnect(); window.removeEventListener('resize', measure) })
  })
  usePopoverDismissal({ isOpen: open, canDismiss: () => true,
    contains: (target) => root.contains(target) || Boolean(menu?.contains(target)),
    onDismiss: (restore) => { setOpen(false); if (restore) more.focus() } })
  const select = (value: Value) => {
    props.onSelect(value); setOpen(false)
    queueMicrotask(() => root.querySelector<HTMLButtonElement>(`[id="${tabId(props.idPrefix, value)}"]`)?.focus())
  }
  const move = (event: KeyboardEvent, index: number) => {
    const next = nextEnabledTabIndex(props.tabs, index, event.key)
    if (next === undefined) return
    event.preventDefault()
    const target = props.tabs[next]
    if (target) select(target.value)
  }
  return <div ref={root} class="pane-tabs pane-tabs-overflow">
    <div ref={strip} class="pane-tabs-visible" role="tablist" aria-label={props.label}>
      <For each={props.tabs}>{(tab, index) => <button type="button" role="tab" title={tab.title ?? tab.label}
        id={tabId(props.idPrefix, tab.value)} aria-selected={tab.value === props.active}
        aria-controls={tabPanelId(props.idPrefix, tab.value)} disabled={tab.disabled ?? false}
        hidden={!visible().includes(tab.value)} tabIndex={tab.value === props.active && !tab.disabled ? 0 : -1}
        classList={{ 'pane-tab': true, active: tab.value === props.active }}
        onKeyDown={(event) => move(event, index())} onClick={() => { if (!tab.disabled) props.onSelect(tab.value) }}
      >{tab.label}</button>}</For>
    </div>
    <button ref={more} type="button" class="workspace-icon pane-tabs-more" aria-label="More tabs" title="Show the remaining tabs"
      style={{ visibility: overflow().length ? 'visible' : 'hidden', position: overflow().length ? undefined : 'absolute' }}
      tabIndex={overflow().length ? 0 : -1} aria-hidden={!overflow().length} aria-expanded={open()} aria-haspopup="menu"
      onClick={() => { locateMenu(); setOpen(!open()) }}
      onKeyDown={(event) => { if (event.key === 'ArrowDown') { event.preventDefault(); locateMenu(); setOpen(true); queueMicrotask(() => menu?.querySelector<HTMLElement>('button:not(:disabled)')?.focus()) } }}><WorkspaceIcon name="more" /></button>
    <div ref={measuring} class="pane-tabs-measure" aria-hidden="true"><For each={props.tabs}>{(tab) => <span class="pane-tab">{tab.label}</span>}</For></div>
    <Show when={open() && overflow().length}><Portal><div ref={menu} class="pane-tabs-menu" role="menu" aria-label="More tabs"
      style={{ position: 'fixed', top: `${position().top}px`, right: `${position().right}px` }}
      onKeyDown={(event) => {
        const items = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
        const index = items.indexOf(document.activeElement as HTMLButtonElement)
        const next = event.key === 'ArrowDown' ? (index + 1) % items.length : event.key === 'ArrowUp' ? (index - 1 + items.length) % items.length : event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : undefined
        if (next !== undefined) { event.preventDefault(); items[next]?.focus() }
      }}>
      <For each={overflow()}>{(tab) => <button type="button" role="menuitem" disabled={tab.disabled} title={tab.title ?? tab.label}
        onClick={() => select(tab.value)}>{tab.label}</button>}</For>
    </div></Portal></Show>
  </div>
}

export function nextEnabledTabIndex<Value extends string>(
  tabs: readonly TabDescriptor<Value>[],
  currentIndex: number,
  key: string,
): number | undefined {
  if (tabs.length === 0) return undefined
  if (key === 'Home') return validIndex(tabs.findIndex((tab) => !tab.disabled))
  if (key === 'End') {
    for (let index = tabs.length - 1; index >= 0; index -= 1) {
      if (!tabs[index]?.disabled) return index
    }
    return undefined
  }
  const direction = key === 'ArrowRight' ? 1 : key === 'ArrowLeft' ? -1 : 0
  if (direction === 0) return undefined
  for (let offset = 1; offset <= tabs.length; offset += 1) {
    const candidate = (currentIndex + direction * offset + tabs.length) % tabs.length
    if (!tabs[candidate]?.disabled) return candidate
  }
  return undefined
}

function validIndex(index: number): number | undefined {
  return index >= 0 ? index : undefined
}

/** The panel element always exists so the tab's `aria-controls` resolves, but
 * its content is mounted only while selected — a hidden tab must not keep
 * fetching in the background. */
export function TabPanel(props: {
  idPrefix: string
  value: string
  active: string
  children: JSX.Element
}): JSX.Element {
  const selected = () => props.value === props.active
  return (
    <div
      role="tabpanel"
      id={tabPanelId(props.idPrefix, props.value)}
      aria-labelledby={tabId(props.idPrefix, props.value)}
      class="pane-panel"
      hidden={!selected()}
      tabIndex={0}
    ><Show when={selected()}>{props.children}</Show></div>
  )
}

export function tabId(prefix: string, value: string): string {
  return `${prefix}-tab-${value}`
}

export function tabPanelId(prefix: string, value: string): string {
  return `${prefix}-panel-${value}`
}
