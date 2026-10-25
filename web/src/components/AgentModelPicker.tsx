import { For, createMemo, createSignal, createUniqueId, type JSX } from 'solid-js'
import type { AgentModel } from '../notes/types'
import { providerLabel } from './UserAgentSettings'
import { usePopoverDismissal } from './usePopoverDismissal'
import './agent-model-picker.css'

export function AgentModelPicker(props: {
  models: readonly AgentModel[]; selectedModel?: string; selectedProvider?: string; disabled: boolean
  onSelect(model: string, provider?: string): void
}): JSX.Element {
  const [open, setOpen] = createSignal(false)
  const [query, setQuery] = createSignal('')
  const [active, setActive] = createSignal(0)
  const id = createUniqueId()
  let root!: HTMLDivElement
  let input!: HTMLInputElement
  const label = (model: AgentModel) => `${providerLabel(model.provider ?? props.selectedProvider ?? 'server')} · ${model.displayName ?? model.modelId}`
  const selected = createMemo(() => props.models.find((model) => model.modelId === props.selectedModel && (!props.selectedProvider || model.provider === props.selectedProvider))
    ?? props.models.find((model) => model.modelId === props.selectedModel))
  const matches = createMemo(() => props.models.filter((model) => `${label(model)} ${model.modelId}`.toLocaleLowerCase().includes(query().trim().toLocaleLowerCase())))
  const choose = (model: AgentModel) => { props.onSelect(model.modelId, model.provider); setOpen(false); setQuery(''); input.focus() }
  usePopoverDismissal({ isOpen: open, canDismiss: () => true, contains: (target) => root.contains(target), onDismiss: (restore) => { setOpen(false); setQuery(''); if (restore) input.focus() } })
  return <div ref={root} class="agent-model-picker">
    <input ref={input} type="text" role="combobox" aria-label="Agent model" title="Choose a model across vendors; type any part of its name"
      aria-expanded={open()} aria-controls={id} aria-autocomplete="list" aria-activedescendant={open() && matches().length ? `${id}-${active()}` : undefined}
      disabled={props.disabled} value={open() ? query() : selected() ? label(selected()!) : props.selectedModel ?? ''}
      placeholder="Filter models…" onFocus={() => { setQuery(''); setActive(0); setOpen(true) }}
      onInput={(event) => { setQuery(event.currentTarget.value); setActive(0); setOpen(true) }}
      onKeyDown={(event) => {
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
          event.preventDefault(); setOpen(true)
          setActive((index) => Math.max(0, Math.min(matches().length - 1, index + (event.key === 'ArrowDown' ? 1 : -1))))
        } else if (event.key === 'Enter' && open()) {
          event.preventDefault(); event.stopPropagation(); const model = matches()[active()]; if (model) choose(model)
        }
      }} />
    <div hidden={!open()} class="agent-model-options" id={id} role="listbox" aria-label="Available models">
      <For each={matches()} fallback={<p class="pane-empty">No matching models.</p>}>{(model, index) =>
        <button type="button" id={`${id}-${index()}`} role="option" aria-selected={selected() === model}
          classList={{ active: active() === index() }} title={model.description ?? label(model)}
          onMouseDown={(event) => event.preventDefault()} onClick={() => choose(model)}>{label(model)}</button>
      }</For>
    </div>
  </div>
}
