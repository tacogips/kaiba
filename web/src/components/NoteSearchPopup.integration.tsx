import { Show, createSignal } from 'solid-js'
import { render } from 'solid-js/web'
import { expect, test } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import { NoteSearchPopup } from './NoteSearchPopup'

test('quick search contains keyboard focus and restores it after Escape from a button', () => {
  const host = document.createElement('div')
  document.body.append(host)
  const [open, setOpen] = createSignal(false)
  const dispose = render(() => <>
    <button onClick={() => setOpen(true)}>Open search</button>
    <Show when={open()}><NoteSearchPopup client={{} as NoteGraphQLClient} tags={[]}
      onOpenNote={() => undefined} onClose={() => setOpen(false)} /></Show>
  </>, host)
  try {
    const opener = host.querySelector('button')!
    opener.focus()
    opener.click()
    expect(document.activeElement?.getAttribute('aria-label')).toBe('Search full note text')
    const close = host.querySelector<HTMLButtonElement>('button[aria-label="Close search"]')!
    close.focus()
    close.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true }))
    expect(document.activeElement?.getAttribute('aria-label')).toBe('Search full note text')
    document.activeElement!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }))
    expect(document.activeElement).toBe(close)
    close.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    expect(host.querySelector('[role="dialog"]')).toBeNull()
    expect(document.activeElement).toBe(opener)
  } finally { dispose(); host.remove() }
})
