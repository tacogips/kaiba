import { render } from 'solid-js/web'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import type { NoteGraphQLClient } from '../notes/client'
import { AppStoreProvider, useApp, type AppStore } from '../state/appStore'
import { TagPane } from './TagPane'
import { notebookId, noteId, tagId } from '../notes/ids'

// The tag entity page (design-docs/specs/note-capture-and-entity-pages.md,
// E3/E4/E5): the header binds a canonical note to the tag, or offers the ways
// to create one, and the co-occurring chips are how one entity leads to the
// next.

const subject = { tagId: 'topic-kaiba', name: 'kaiba', isSystem: false }
const neighbour = { tagId: 'topic-notes', name: 'notes', isSystem: false }

const description = {
  noteId: noteId('note-description'), notebookId: notebookId('notebook-tag-memo'), noteNumber: 4,
  title: 'Kaiba', bodyMarkdown: '# Kaiba\n\nA note store with a chatbook reader.', readOnly: false,
  createdAt: '2026-09-21', updatedAt: '2026-09-21', tags: [],
}

function detail(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    tag: subject,
    tagClass: null,
    noteCount: 7,
    notebookCount: 2,
    memoNotebookId: null,
    canonicalNote: null,
    coOccurringTags: [{ tag: neighbour, noteCount: 3 }],
    ...overrides,
  }
}

function client(overrides: Partial<Record<string, unknown>>): NoteGraphQLClient {
  return {
    initialize: async () => undefined,
    streamHeaders: () => ({}),
    appSetting: async () => undefined,
    tags: async () => [subject, neighbour],
    tagClasses: async () => [],
    notebooks: async () => [],
    notes: async () => [],
    noteComments: async () => [],
    notebookComments: async () => [],
    noteConversations: async () => [],
    notebookConversations: async () => [],
    tagComments: async () => [],
    notesByTag: async () => [],
    agentModels: async () => ({ models: [], configuredModel: '' }),
    useCredential: () => undefined,
    clearCredential: () => undefined,
    hasCredential: () => true,
    ...overrides,
  } as unknown as NoteGraphQLClient
}

function router(initial: string): { currentHash: () => string; setHash: (next: string) => void;
  addListener: (listener: () => void) => void; removeListener: (listener: () => void) => void;
  hash: () => string } {
  let hash = initial
  const listeners = new Set<() => void>()
  return {
    hash: () => hash,
    currentHash: () => hash,
    setHash: (next: string) => { hash = next; for (const listener of listeners) listener() },
    addListener: (listener: () => void) => { listeners.add(listener) },
    removeListener: (listener: () => void) => { listeners.delete(listener) },
  }
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 4; tick += 1) {
    await new Promise<void>((resolve) => window.setTimeout(resolve, 0))
  }
}

let originalFetch: typeof fetch

beforeEach(() => {
  window.location.hash = ''
  originalFetch = globalThis.fetch
  globalThis.fetch = (() => new Promise<Response>(() => undefined)) as unknown as typeof fetch
})

afterEach(() => {
  globalThis.fetch = originalFetch
})

function mount(api: NoteGraphQLClient, routes = router('#/note/open-note')): {
  host: HTMLElement; dispose: () => void; store: () => AppStore; hash: () => string
} {
  const host = document.createElement('div')
  document.body.append(host)
  let store: AppStore | undefined
  const Probe = () => { store = useApp(); return null }
  const dispose = render(() => (
    <AppStoreProvider options={{ client: api, router: routes }}>
      <Probe />
      <TagPane tagId={tagId('topic-kaiba')} />
    </AppStoreProvider>
  ), host)
  return { host, dispose, store: () => store!, hash: routes.hash }
}

function button(host: HTMLElement, label: string): HTMLButtonElement | undefined {
  return Array.from(host.querySelectorAll('button')).find((item) => item.textContent?.trim() === label)
}

describe('tag entity header', () => {
  test('renders the canonical note with an excerpt, an open link and an unbind control', async () => {
    let unpromoted = 0
    const bound = detail({ canonicalNote: description })
    const { host, dispose, hash } = mount(client({
      tagDetail: async () => unpromoted === 0 ? bound : detail(),
      note: async () => description,
      unpromoteTagNote: async () => { unpromoted += 1 },
    }))
    try {
      await settle()
      const section = host.querySelector('[aria-label="Tag description"]')!
      expect(section.textContent).toContain('A note store with a chatbook reader.')
      expect(button(host, 'Write a description')).toBeUndefined()

      button(host, 'Open Kaiba')!.click()
      await settle()
      expect(hash()).toContain('#/note/note-description')

      button(host, 'Unbind')!.click()
      await settle()
      expect(unpromoted).toBe(1)
      // The header re-reads its own detail rather than waiting for the feed.
      expect(host.querySelector('[aria-label="Tag description"]')?.textContent)
        .toContain('No description note for this tag yet.')
    } finally { dispose(); host.remove() }
  })

  test('promotes the open note when the tag has no description', async () => {
    const promoted: Array<[string, string]> = []
    const { host, dispose } = mount(client({
      note: async () => ({ ...description, noteId: noteId('open-note'), notebookId: notebookId('notebook-a') }),
      tagDetail: async () => promoted.length === 0
        ? detail()
        : detail({ canonicalNote: { ...description, noteId: noteId('open-note') } }),
      promoteTagNote: async (tag: string, note: string) => { promoted.push([tag, note]) },
    }))
    try {
      await settle()
      button(host, 'Use the open note')!.click()
      await settle()
      expect(promoted).toEqual([['topic-kaiba', 'open-note']])
      expect(host.querySelector('[aria-label="Tag description"]')?.textContent)
        .toContain('A note store with a chatbook reader.')
    } finally { dispose(); host.remove() }
  })

  test('writes a description into the tag memo notebook and promotes it in one flow', async () => {
    const order: string[] = []
    const created: Array<[string, string]> = []
    let bound = false
    const { host, dispose } = mount(client({
      tagDetail: async () => bound ? detail({ canonicalNote: description, memoNotebookId: description.notebookId }) : detail(),
      ensureTagMemoNotebook: async () => {
        order.push('ensureTagMemoNotebook')
        return { notebookId: description.notebookId, type: 'DOCUMENT', title: '#kaiba', readOnly: false,
          createdAt: '2026-09-21', updatedAt: '2026-09-21', tags: [] }
      },
      createNote: async (notebook: string, body: string) => {
        order.push('createNote')
        created.push([notebook, body])
        return description
      },
      promoteTagNote: async () => { order.push('promoteTagNote'); bound = true },
    }))
    try {
      await settle()
      button(host, 'Write a description')!.click()
      const draft = host.querySelector<HTMLTextAreaElement>('#tag-description')!
      draft.value = 'A note store with a chatbook reader.'
      draft.dispatchEvent(new Event('input', { bubbles: true }))
      host.querySelector('[aria-label="Tag description"] form')!
        .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
      await settle()
      // E3 orders the three existing calls; a description note is never
      // created outside the tag's own memo notebook.
      expect(order).toEqual(['ensureTagMemoNotebook', 'createNote', 'promoteTagNote'])
      expect(created).toEqual([['notebook-tag-memo', 'A note store with a chatbook reader.']])
      expect(host.querySelector('#tag-description')).toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('reports a refused promote without losing the header', async () => {
    const { host, dispose } = mount(client({
      tagDetail: async () => detail(),
      note: async () => ({ ...description, noteId: noteId('open-note') }),
      promoteTagNote: async () => { throw new Error('tag is a folder tag') },
    }))
    try {
      await settle()
      button(host, 'Use the open note')!.click()
      await settle()
      expect(host.querySelector('[aria-label="Tag description"] [role="alert"]')?.textContent)
        .toContain('tag is a folder tag')
      expect(button(host, 'Use the open note')).toBeDefined()
    } finally { dispose(); host.remove() }
  })

  test('withholds the promote controls for tags the server always refuses', async () => {
    // E2 / NoteService.requireCanonicalPromotable rejects folder-class and
    // document-kind tags, so offering the controls would only teach the
    // refusal by attempting it.
    const { host, dispose } = mount(client({
      tagDetail: async () => detail({ tag: { ...subject, classId: 'folder' } }),
      note: async () => description,
    }))
    try {
      await settle()
      expect(button(host, 'Use the open note')).toBeUndefined()
      expect(button(host, 'Write a description')).toBeUndefined()
      expect(host.querySelector('[aria-label="Tag description"]')?.textContent)
        .toContain('Organizational tags carry no description')
    } finally { dispose(); host.remove() }
  })

  test('a refused promote keeps the written note so a retry binds it instead of writing another', async () => {
    const created: string[] = []
    const promotes: string[] = []
    let refuse = true
    let bound = false
    const { host, dispose } = mount(client({
      tagDetail: async () => bound ? detail({ canonicalNote: description }) : detail(),
      ensureTagMemoNotebook: async () => ({ notebookId: description.notebookId, type: 'DOCUMENT',
        title: '#kaiba', readOnly: false, createdAt: '2026-09-21', updatedAt: '2026-09-21', tags: [] }),
      createNote: async (_notebook: string, body: string) => {
        created.push(body)
        return description
      },
      promoteTagNote: async (_tag: string, note: string) => {
        promotes.push(note)
        if (refuse) throw new Error('promote refused')
        bound = true
      },
    }))
    try {
      await settle()
      button(host, 'Write a description')!.click()
      const draft = host.querySelector<HTMLTextAreaElement>('#tag-description')!
      draft.value = 'A note store with a chatbook reader.'
      draft.dispatchEvent(new Event('input', { bubbles: true }))
      const submit = () => host.querySelector('[aria-label="Tag description"] form')!
        .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))

      submit()
      await settle()
      expect(created).toEqual(['A note store with a chatbook reader.'])
      expect(host.querySelector('[aria-label="Tag description"] [role="alert"]')?.textContent)
        .toContain('promote refused')
      // The already-written note is remembered, and the control says so.
      expect(button(host, 'Retry promoting it')).toBeDefined()

      refuse = false
      submit()
      await settle()
      // Retry re-promotes the same note; the memo notebook gains nothing new.
      expect(created).toEqual(['A note store with a chatbook reader.'])
      expect(promotes).toEqual(['note-description', 'note-description'])
      expect(host.querySelector('#tag-description')).toBeNull()
    } finally { dispose(); host.remove() }
  })

  test('co-occurring chips open their own entity page and Back returns to this one', async () => {
    const routes = router('#/note/open-note')
    const { host, dispose, store, hash } = mount(client({
      tagDetail: async () => detail(),
      note: async () => description,
    }), routes)
    try {
      await settle()
      const chip = host.querySelector<HTMLButtonElement>('[aria-label="Tags seen with this one"] .tag-chip-open')!
      expect(chip.textContent).toBe('notes')
      expect(host.querySelector('[aria-label="Tags seen with this one"]')?.textContent).toContain('3')
      chip.click()
      await settle()
      expect(hash()).toContain('tag=topic-notes')
      store().goBack()
      await settle()
      expect(hash()).not.toContain('tag=topic-notes')
    } finally { dispose(); host.remove() }
  })
})
