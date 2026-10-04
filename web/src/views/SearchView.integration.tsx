import { noteId as asNoteId, notebookId as asNotebookId } from '../notes/ids'
import { render } from 'solid-js/web'
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { NoteTransportError, type NoteGraphQLClient } from '../notes/client'
import type { EngineNoteHit, Note, NoteSearchResult } from '../notes/types'
import type { RouterEnvironment } from '../router'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import type { JSX } from 'solid-js'
import { SearchView } from './SearchView'

const note: Note = {
  noteId: asNoteId('search-hit'), notebookId: asNotebookId('book'), noteNumber: 3,
  title: 'Search hit', bodyMarkdown: 'Stored note body', readOnly: false,
  createdAt: '', updatedAt: '',
}
const engineHit: EngineNoteHit = { note, snippet: 'Engine snippet', score: 4 }
const builtInHit: NoteSearchResult = {
  note, snippet: 'Built in snippet', rank: 1, matchedTags: [], isLinkedNeighbor: false, termCoverage: 1,
}

let originalFetch: typeof fetch

beforeEach(() => {
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})

afterEach(() => { globalThis.fetch = originalFetch })

function mountSearch(options: {
  enabled: boolean
  engineSearchNotes: () => Promise<EngineNoteHit[]>
  searchNotes: () => Promise<NoteSearchResult[]>
}): { host: HTMLElement; dispose: () => void } {
  let hash = '#/search?q=neuron&scope=all&method=grep'
  const listeners = new Set<() => void>()
  const router: RouterEnvironment = {
    currentHash: () => hash,
    setHash: (next) => { hash = next; for (const listener of listeners) listener() },
    addListener: (listener) => { listeners.add(listener) },
    removeListener: (listener) => { listeners.delete(listener) },
  }
  const api = {
    initialize: async () => undefined,
    searchEngineCapability: async () => options.enabled,
    engineSearchNotes: options.engineSearchNotes,
    searchNotes: options.searchNotes,
    appSetting: async () => undefined,
    tags: async () => [],
    tagClasses: async () => [],
    notebooks: async () => [],
    streamHeaders: () => ({}),
  } as unknown as NoteGraphQLClient
  const host = document.createElement('div')
  document.body.append(host)
  const dispose = render(() => (
    <AppStoreProvider options={{ client: api, router }}>
      <SearchView />
    </AppStoreProvider>
  ), host)
  return { host, dispose }
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 5; tick += 1) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  }
}

function CaptureAppStore(props: { capture: (store: AppStore) => void }): JSX.Element {
  props.capture(useApp())
  return <></>
}

describe('SearchView engine search', () => {
  test('uses built-in search when capability is disabled', async () => {
    const engineSearchNotes = vi.fn(async () => [engineHit])
    const searchNotes = vi.fn(async () => [builtInHit])
    const { host, dispose } = mountSearch({ enabled: false, engineSearchNotes, searchNotes })
    try {
      await settle()
      expect(searchNotes).toHaveBeenCalled()
      expect(engineSearchNotes).not.toHaveBeenCalled()
      expect(host.textContent).toContain('Built in snippet')
    } finally { dispose(); host.remove() }
  })

  test('uses engine search and displays its snippet when enabled', async () => {
    const engineSearchNotes = vi.fn(async () => [engineHit])
    const searchNotes = vi.fn(async () => [builtInHit])
    const { host, dispose } = mountSearch({ enabled: true, engineSearchNotes, searchNotes })
    try {
      await settle()
      expect(engineSearchNotes).toHaveBeenCalledWith({ query: 'neuron', limit: 50 })
      expect(searchNotes).toHaveBeenCalledTimes(1)
      expect(host.textContent).toContain('Engine snippet')
    } finally { dispose(); host.remove() }
  })

  test.each(['search-engine-unavailable', 'feature-disabled'])(
    'falls back only for %s and shows the pinned notice', async (resultStatus) => {
      const engineSearchNotes = vi.fn(async () => {
        throw new NoteTransportError('engine unavailable', 'result', undefined, resultStatus)
      })
      const searchNotes = vi.fn(async () => [builtInHit])
      const { host, dispose } = mountSearch({ enabled: true, engineSearchNotes, searchNotes })
      try {
        await settle()
        expect(searchNotes).toHaveBeenCalledWith({ query: 'neuron', limit: 50 })
        expect(host.querySelector('[role="status"]')?.textContent)
          .toBe('Search engine unavailable; showing built-in results')
      } finally { dispose(); host.remove() }
    },
  )

  test('keeps the existing error path for unrelated engine failures', async () => {
    const engineSearchNotes = vi.fn(async () => { throw new NoteTransportError('offline', 'network') })
    const searchNotes = vi.fn(async () => [builtInHit])
    const { host, dispose } = mountSearch({ enabled: true, engineSearchNotes, searchNotes })
    try {
      await settle()
      expect(searchNotes).toHaveBeenCalledTimes(1)
      expect(host.querySelector('[role="alert"]')?.textContent).toContain('offline')
      expect(host.querySelector('[role="status"]')).toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('loads search capability again after successful sign-in', async () => {
    let authorized = false
    let capabilityRequests = 0
    const unauthorized = () => new NoteTransportError('note API requires a bearer token', 'http', 401)
    const api = {
      initialize: async () => undefined,
      streamHeaders: () => ({}),
      searchEngineCapability: async () => {
        capabilityRequests += 1
        if (!authorized) throw unauthorized()
        return true
      },
      tags: async () => {
        if (!authorized) throw unauthorized()
        return []
      },
      tagClasses: async () => [],
      notebooks: async () => [],
      appSetting: async () => undefined,
      useCredential: () => { authorized = true },
      clearCredential: () => { authorized = false },
    } as unknown as NoteGraphQLClient
    const router: RouterEnvironment = {
      currentHash: () => '#/',
      setHash: () => undefined,
      addListener: () => undefined,
      removeListener: () => undefined,
    }
    const host = document.createElement('div')
    document.body.append(host)
    let store: AppStore | undefined
    const dispose = render(() => (
      <AppStoreProvider options={{ client: api, router }}>
        <CaptureAppStore capture={(value) => { store = value }} />
      </AppStoreProvider>
    ), host)
    try {
      await settle()
      expect(store?.state.searchEngineEnabled).toBe(false)
      expect(capabilityRequests).toBe(1)
      await store?.signInWithKey('valid-key')
      expect(store?.state.searchEngineEnabled).toBe(true)
      expect(capabilityRequests).toBe(2)
    } finally { dispose(); host.remove() }
  })
})
