import { For, Show, createEffect, createMemo, createSignal, createUniqueId, on, type JSX } from 'solid-js'
import { matchingTranslationLanguages, translationLanguages } from '../notes/translationLanguages'

/** An editable language combobox with explicit prefix filtering and keyboard selection. */
export function TranslationLanguagePicker(props: { value: string; disabled: boolean; onChange: (value: string) => void }): JSX.Element {
  const [query, setQuery] = createSignal(props.value)
  const [expanded, setExpanded] = createSignal(true)
  const [active, setActive] = createSignal(0)
  const listId = createUniqueId()
  let input!: HTMLInputElement
  let container!: HTMLDivElement
  const matches = createMemo(() => matchingTranslationLanguages(query()))
  const custom = () => matches().length === 0 && query().trim().length > 0
  const count = () => custom() ? 1 : matches().length
  createEffect(on(() => props.value, (value) => { if (value) setQuery(value) }))
  const choose = (value: string) => {
    props.onChange(value); setQuery(value); input.focus(); setExpanded(false)
  }
  createEffect(() => {
    const index = active()
    count()
    if (expanded()) queueMicrotask(() => document.getElementById(`${listId}-${index}`)?.scrollIntoView?.({ block: 'nearest' }))
  })
  return <div class="translation-language-picker" ref={container}>
    <label>Target language
      <input ref={input} autofocus role="combobox" aria-label="Target language" aria-autocomplete="list" autocomplete="off"
        aria-expanded={expanded()} aria-controls={listId}
        aria-activedescendant={expanded() && count() ? `${listId}-${active()}` : undefined}
        value={query()} placeholder="Filter languages…" disabled={props.disabled}
        onFocus={() => setExpanded(true)} onBlur={(event) => {
          if (!(event.relatedTarget instanceof Node) || !container.contains(event.relatedTarget)) setExpanded(false)
        }}
        onInput={(event) => {
          const text = event.currentTarget.value
          setQuery(text); setActive(0); setExpanded(true)
          const exact = translationLanguages.find((language) => language.name.toLocaleLowerCase() === text.trim().toLocaleLowerCase())
          props.onChange(exact?.name ?? '')
        }}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault(); event.stopPropagation(); setExpanded(true)
            setActive((index) => Math.max(0, Math.min(count() - 1, index + (event.key === 'ArrowDown' ? 1 : -1))))
          } else if (event.key === 'Enter' && expanded()) {
            event.preventDefault(); event.stopPropagation()
            const value = custom() ? query().trim() : matches()[active()]?.name
            if (value) choose(value)
          } else if (event.key === 'Escape' && expanded()) {
            event.preventDefault(); event.stopPropagation(); setExpanded(false)
          } else if (event.key === 'Tab') setExpanded(false)
        }} />
    </label>
    <Show when={expanded()}>
      <div class="translation-language-options" id={listId} role="listbox" aria-label="Target languages">
        <For each={matches()}>{(language, index) => <button type="button" role="option" tabindex="-1"
          id={`${listId}-${index()}`} aria-selected={language.name === props.value} classList={{ 'language-active': index() === active() }}
          disabled={props.disabled} onMouseDown={(event) => event.preventDefault()} onClick={() => choose(language.name)}>
          <span>{language.name}</span><Show when={language.nativeName !== language.name}><small>{language.nativeName}</small></Show>
        </button>}</For>
        <Show when={custom()}><button type="button" role="option" tabindex="-1" id={`${listId}-0`} aria-selected={false}
          disabled={props.disabled} onMouseDown={(event) => event.preventDefault()} onClick={() => choose(query().trim())}>Use “{query().trim()}”</button></Show>
      </div>
    </Show>
  </div>
}
