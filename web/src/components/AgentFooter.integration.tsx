import { render } from 'solid-js/web'
import { expect, test } from 'vitest'
import { AppStoreProvider } from '../state/appStore'
import type { NoteGraphQLClient } from '../notes/client'
import { AgentFooter } from './AgentFooter'

test('bottom pane resizes, restores its size after fullscreen, and collapses from its top toolbar', async () => {
  const savedFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
  const host = document.createElement('div'); document.body.append(host)
  const api = { initialize: async () => {}, streamHeaders: () => ({}), appSetting: async () => undefined,
    tags: async () => [], tagClasses: async () => [], notebooks: async () => [], agentModels: async () => ({ models: [] }),
  } as unknown as NoteGraphQLClient
  const dispose = render(() => <AppStoreProvider options={{ client: api }}><AgentFooter onConversation={() => {}} /></AppStoreProvider>, host)
  try {
    for (let i = 0; i < 4; i++) await new Promise((resolve) => setTimeout(resolve, 0))
    host.querySelector<HTMLButtonElement>('[aria-label="Ask AI"]')!.click()
    const footer = host.querySelector('footer')!
    const handle = host.querySelector<HTMLElement>('[aria-label="Resize the bottom pane"]')!
    handle.setPointerCapture = () => {}
    footer.getBoundingClientRect = () => ({ height: 250 }) as DOMRect
    handle.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, button: 0, clientY: 500, bubbles: true }))
    handle.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientY: 400 }))
    handle.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1 }))
    expect(footer.style.height).toBe('350px')
    host.querySelector<HTMLButtonElement>('[aria-label="Full screen"]')!.click()
    expect(footer.dataset.large).toBe('true')
    expect(host.querySelector('[aria-label="Exit full screen"]')).not.toBeNull()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    expect(footer.dataset.large).toBe('false'); expect(footer.style.height).toBe('350px')
    const close = host.querySelector<HTMLButtonElement>('[aria-label="Close AI composer"]')!
    expect(close.closest('.footer-chat-tools')).not.toBeNull()
    close.click()
    expect(host.querySelector('[aria-label="Resize the bottom pane"]')).toBeNull()
    expect(footer.style.height).toBe('')
    host.querySelector<HTMLButtonElement>('[aria-label="Ask AI"]')!.click()
    expect(footer.style.height).toBe('350px')
    host.querySelector<HTMLElement>('[aria-label="Resize the bottom pane"]')!.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
    expect(footer.style.height).toBe('')
  } finally { dispose(); host.remove(); globalThis.fetch = savedFetch }
})
