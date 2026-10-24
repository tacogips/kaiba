import { render } from 'solid-js/web'
import { describe, expect, test, vi } from 'vitest'
import { noteId, notebookId } from '../notes/ids'
import { LinkedDocsTab } from './LinkedDocsTab'
import type { NoteGraphNeighbor, NoteLink } from '../notes/types'

const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))
const source = noteId('source')
const target = noteId('target')
const neighbor: NoteGraphNeighbor = { seedNoteId: source, edgeKind: 'explicit-link', hopCount: 1, weight: 1, pathNoteIds: [source, target],
  note: { noteId: target, notebookId: notebookId('other'), noteNumber: 4, title: 'Source passage', bodyMarkdown: 'Cited words', readOnly: false,
    createdAt: '', updatedAt: '', metaJSON: null } }

function mount(links: NoteLink[]) {
  const openNote = vi.fn()
  fixture.app = { state: { noteId: source, notebookId: notebookId('current'), notebookRevisions: {},
    notebooks: [{ notebookId: notebookId('other'), title: 'Reference notebook' }] },
    client: { noteGraphNeighbors: vi.fn(async () => [neighbor, { ...neighbor, edgeKind: 'shared-tag' }, { ...neighbor, edgeKind: 'lexical' }]),
      noteLinks: vi.fn(async () => links) }, openNote }
  const host = document.createElement('div'); document.body.append(host)
  const dispose = render(() => <LinkedDocsTab />, host)
  return { host, close: () => { dispose(); host.remove() } }
}

describe('Link meaning and destination', () => {
  test('separates saved link types and direction from inferred connections', async () => {
    const view = mount([{ fromNoteId: source, toNoteId: target, linkKind: 'source-citation', provenance: 'human', createdAt: '' }])
    try {
      await vi.waitFor(() => expect(view.host.textContent).toContain('Saved link to this destination · source citation · Added manually'))
      expect([...view.host.querySelectorAll('h3')].map((item) => item.textContent)).toEqual(['Saved links', 'Similar text', 'Shared tags'])
      expect(view.host.textContent).toContain('Reference notebook · Note 4')
      expect(view.host.textContent).toContain('this is not a saved link')
      expect(view.host.textContent).not.toContain('1 hop')
    } finally { view.close() }
  })

  test('shows incoming links from the destination to the current page', async () => {
    const view = mount([{ fromNoteId: target, toNoteId: source, linkKind: 'reference', provenance: 'ai', createdAt: '' }])
    try { await vi.waitFor(() => expect(view.host.textContent).toContain('Saved link from this destination · reference · Added by ai')) }
    finally { view.close() }
  })
})
