import { For, Show, type JSX } from 'solid-js'

// One accessible tab strip for both side panes: roving tab stop, arrow-key
// movement, and the `tablist`/`tab`/`tabpanel` wiring the panes rely on.

export interface TabDescriptor<Value extends string> {
  value: Value
  label: string
  disabled?: boolean
}

export function Tabs<Value extends string>(props: {
  label: string
  tabs: readonly TabDescriptor<Value>[]
  active: Value
  idPrefix: string
  onSelect: (value: Value) => void
}): JSX.Element {
  const move = (event: KeyboardEvent, index: number) => {
    const next = nextEnabledTabIndex(props.tabs, index, event.key)
    if (next === undefined) return
    event.preventDefault()
    const target = props.tabs[next]
    if (!target) return
    props.onSelect(target.value)
    const strip = (event.currentTarget as HTMLElement).parentElement
    strip?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next]?.focus()
  }
  return (
    <div class="pane-tabs" role="tablist" aria-label={props.label}>
      <For each={props.tabs}>{(tab, index) => {
        const selected = () => tab.value === props.active
        const disabled = () => tab.disabled ?? false
        return <button
          type="button"
          role="tab"
          id={tabId(props.idPrefix, tab.value)}
          aria-selected={selected()}
          aria-controls={tabPanelId(props.idPrefix, tab.value)}
          disabled={disabled()}
          tabIndex={selected() && !disabled() ? 0 : -1}
          classList={{ 'pane-tab': true, active: selected() }}
          onKeyDown={(event) => move(event, index())}
          onClick={() => { if (!disabled()) props.onSelect(tab.value) }}
        >{tab.label}</button>
      }}</For>
    </div>
  )
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
