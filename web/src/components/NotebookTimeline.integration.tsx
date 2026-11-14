import { render } from 'solid-js/web'
import { describe, expect, test } from 'vitest'
import { notebookId } from '../notes/ids'
import type { NoteGraphQLClient } from '../notes/client'
import { AppStoreProvider, useApp } from '../state/appStore'
import { LeftPane } from '../panes/LeftPane'
import { defaultPaneState, parsePaneState } from '../state/paneState'

describe('notebook views', () => {
  test('orders all library types by update instant, persists the mode, and navigates', async () => {
    let entries = [
      { notebookId: notebookId('old'), title: 'Old', updatedAt: '2026-01-01', type: 'DOCUMENT' },
      { notebookId: notebookId('new'), title: 'New', updatedAt: '2026-01-03T00:00:00Z', type: 'DIARY' },
      { notebookId: notebookId('middle'), title: 'Middle', updatedAt: '2026-01-03T08:00:00+09:00', type: 'DOCUMENT' },
      { notebookId: notebookId('chat'), title: 'Hidden chat', updatedAt: '2026-01-04', type: 'AGENT_CHAT' },
    ].map((item) => ({ ...item, createdAt: '2026-01-01', readOnly: false, tags: [] }))
    const client = { initialize: async () => {}, streamHeaders: () => ({}), notebooks: async () => entries,
      tags: async () => [], tagClasses: async () => [], appSetting: async () => undefined,
      notebook: async () => entries[1], notes: async () => [] } as unknown as NoteGraphQLClient
    let stored = JSON.stringify(defaultPaneState)
    let hash = '#/'
    let navigated = false
    let app!: ReturnType<typeof useApp>
    const originalFetch = globalThis.fetch
    globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
    const host = document.createElement('div')
    document.body.append(host)
    const dispose = render(() => <AppStoreProvider options={{ client,
      paneStorage: { getItem: () => stored, setItem: (_, value) => { stored = value } },
      router: { currentHash: () => hash, setHash: (value) => { hash = value }, addListener: () => {}, removeListener: () => {} },
    }}>{(() => { app = useApp(); return <LeftPane onNavigate={() => { navigated = true }} /> })()}</AppStoreProvider>, host)
    try {
      for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
      expect(host.querySelector('[role="tree"]')).not.toBeNull()
      host.querySelector<HTMLButtonElement>('[aria-label="Timeline view"]')!.click()
      expect(parsePaneState(stored).notebookView).toBe('timeline')
      expect(host.querySelector('[role="tree"]')).toBeNull()
      expect([...host.querySelectorAll('.notebook-timeline strong')].map((node) => node.textContent)).toEqual(['New', 'Middle', 'Old'])
      host.querySelector<HTMLButtonElement>('.notebook-timeline-entry')!.click()
      expect(hash).toBe('#/notebook/new')
      expect(navigated).toBe(true)
      entries = entries.map((entry) => entry.notebookId === 'old' ? { ...entry, updatedAt: '2026-01-05' } : entry)
      await app.refreshCatalog()
      expect(host.querySelector('.notebook-timeline strong')?.textContent).toBe('Old')
      app.setNotebookView('tree')
      expect(host.querySelector('[role="tree"]')).not.toBeNull()
    } finally { dispose(); host.remove(); globalThis.fetch = originalFetch }
  })
})
