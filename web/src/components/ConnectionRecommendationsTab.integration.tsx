import { render } from 'solid-js/web'
import { expect, test, vi } from 'vitest'
import { ConnectionRecommendationsTab, type ConnectionCategory } from './ConnectionRecommendationsTab'
import { noteId, notebookId } from '../notes/ids'
const fixture = vi.hoisted(() => ({ app: {} as Record<string, unknown> }))
vi.mock('../state/appStore', async (original) => ({ ...await original<object>(), useApp: () => fixture.app }))

test.each(['similar', 'same-topic', 'related-topics'] as ConnectionCategory[])('separates %s recommendations and names tag evidence', async (category) => {
  const make = (id: string) => ({ noteId: noteId(id), notebookId: notebookId('book'), noteNumber: 1, title: id, bodyMarkdown: '', createdAt: '', updatedAt: '', readOnly: false, metaJSON: null })
  const source = make('source')
  fixture.app = { state: { noteId: source.noteId, notebookId: source.notebookId, notebookRevisions: {}, searchEngineEnabled: true, catalogRevision: 0, notebooks: [] },
    notes: () => [source], notebook: () => undefined, client: { noteGraphNeighbors: async () => [],
      relatedNotes: async () => [
        { note: make('Similar result'), score: 1, reasons: [{ kind: 'text-similarity', tags: [] }] },
        { note: make('Same result'), score: 1, reasons: [{ kind: 'shared-tag', tags: ['Graphs'] }] },
        { note: make('Related result'), score: 1, reasons: [{ kind: 'related-tag', tags: ['Networks (via Mathematics)'] }] },
      ] } }
  const host = document.createElement('div')
  const dispose = render(() => <ConnectionRecommendationsTab category={category} />, host)
  try {
    const expected = category === 'similar' ? 'Similar result' : category === 'same-topic' ? 'Same result' : 'Related result'
    await vi.waitFor(() => expect(host.querySelector('.note-destination-open')?.textContent).toContain(expected))
    expect(host.querySelectorAll('.note-destination')).toHaveLength(1)
    if (category === 'same-topic') expect(host.textContent).toContain('Shared tags: Graphs')
    if (category === 'related-topics') expect(host.textContent).toContain('Related tags: Networks (via Mathematics)')
  } finally { dispose() }
})
