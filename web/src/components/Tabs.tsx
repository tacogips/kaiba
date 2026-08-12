import { For, Show, type JSX } from 'solid-js'

// One accessible tab strip for both side panes: roving tab stop, arrow-key
// movement, and the `tablist`/`tab`/`tabpanel` wiring the panes rely on.

export interface TabDescriptor<Value extends string> {
  value: Value
  label: string
}

export function Tabs<Value extends string>(props: {
  label: string
  tabs: readonly TabDescriptor<Value>[]
  active: Value
  idPrefix: string
  onSelect: (value: Value) => void
}): JSX.Element {
  const move = (event: KeyboardEvent, index: number) => {
    const count = props.tabs.length
    if (count === 0) return
    let next = index
    switch (event.key) {
      case 'ArrowRight': next = (index + 1) % count; break
      case 'ArrowLeft': next = (index - 1 + count) % count; break
      case 'Home': next = 0; break
      case 'End': next = count - 1; break
      default: return
    }
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
        return <button
          type="button"
          role="tab"
          id={tabId(props.idPrefix, tab.value)}
          aria-selected={selected()}
          aria-controls={tabPanelId(props.idPrefix, tab.value)}
          tabIndex={selected() ? 0 : -1}
          classList={{ 'pane-tab': true, active: selected() }}
          onKeyDown={(event) => move(event, index())}
          onClick={() => props.onSelect(tab.value)}
        >{tab.label}</button>
      }}</For>
    </div>
  )
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
