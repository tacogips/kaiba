import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { useApp, errorMessage } from '../state/appStore'
import type { EngineNoteHit } from '../notes/types'
import { NoteDestinationLink } from './NoteDestinationLink'

export type ConnectionCategory = 'similar' | 'same-topic' | 'related-topics'
const descriptions = {
  similar: { title: 'Similar text', explanation: 'Pages with similar wording or content.', reason: 'text-similarity', graph: 'lexical' },
  'same-topic': { title: 'Same topic', explanation: 'Pages sharing the same tags.', reason: 'shared-tag', graph: 'shared-tag' },
  'related-topics': { title: 'Related topics', explanation: 'Pages connected through related tags in the tag hierarchy and ontology.', reason: 'related-tag', graph: '' },
} as const

export function ConnectionRecommendationsTab(props: { category: ConnectionCategory }): JSX.Element {
  const app = useApp()
  const [hits, setHits] = createSignal<EngineNoteHit[]>([])
  const [loading, setLoading] = createSignal(false)
  const [error, setError] = createSignal('')
  let generation = 0
  onCleanup(() => { generation += 1 })
  const info = () => descriptions[props.category]
  createEffect(() => {
    const config = info()
    const engine = app.state.searchEngineEnabled
    const sources = app.state.noteId ? app.notes().filter((note) => note.noteId === app.state.noteId)
      : app.notes().slice(0, 40)
    const sourceIds = app.state.noteId ? [app.state.noteId] : sources.map((note) => note.noteId)
    if (app.state.notebookId) void app.state.notebookRevisions[app.state.notebookId]
    void app.state.catalogRevision
    const current = ++generation
    setHits([]); setError('')
    if (!sourceIds.length) { setLoading(false); return }
    if (!engine && props.category === 'related-topics') { setLoading(false); setError('Enable the search engine to find related tag topics.'); return }
    setLoading(true)
    void (async () => {
      const results: EngineNoteHit[] = []
      for (let offset = 0; offset < sourceIds.length; offset += 4) {
        if (current !== generation) return
        const batch = await Promise.all(sourceIds.slice(offset, offset + 4).map(async (id) => {
          const [graph, ranked] = await Promise.all([
            config.graph ? app.client.noteGraphNeighbors(id) : Promise.resolve([]),
            engine ? app.client.relatedNotes(id, 20) : Promise.resolve([]),
          ])
          const source = sources.find((note) => note.noteId === id)
          const inferred: EngineNoteHit[] = graph.filter((neighbor) => neighbor.edgeKind === config.graph).map((neighbor) => ({
            note: neighbor.note, snippet: '', score: neighbor.weight,
            reasons: [{ kind: config.reason, tags: config.graph === 'shared-tag'
              ? neighbor.note.tags?.filter((assignment) => source?.tags?.some((own) => own.tag.tagId === assignment.tag.tagId)).map((assignment) => assignment.tag.name) ?? [] : [] }],
          }))
          return [...inferred, ...ranked.filter((hit) => hit.reasons.some((reason) => reason.kind === config.reason))]
        }))
        results.push(...batch.flat())
      }
      if (current !== generation) return
      const unique = new Map<string, EngineNoteHit>()
      for (const hit of results) {
        const previous = unique.get(hit.note.noteId)
        if (!previous || hit.score > previous.score) unique.set(hit.note.noteId, hit)
      }
      setHits([...unique.values()].sort((left, right) => right.score - left.score))
    })().catch((failure: unknown) => { if (current === generation) setError(errorMessage(failure)) })
      .finally(() => { if (current === generation) setLoading(false) })
  })
  const reason = (hit: EngineNoteHit) => {
    const names = [...new Set(hit.reasons.filter((item) => item.kind === info().reason).flatMap((item) => item.tags))]
    if (names.length) return `${props.category === 'same-topic' ? 'Shared' : 'Related'} tags: ${names.join(', ')}`
    return props.category === 'similar' ? 'Similar wording' : props.category === 'same-topic' ? 'Shared tags' : 'Related through the tag ontology'
  }
  return <section class="pane-section link-group" aria-label={info().title}>
    <h3>{info().title}</h3><p class="connection-explanation">{info().explanation}</p>
    <Show when={!app.state.noteId && app.notebook()?.noteCount && app.notebook()!.noteCount! > 40}><p class="pane-note">Using the first 40 loaded pages of this notebook.</p></Show>
    <Show when={loading()}><p role="status">Finding connections…</p></Show>
    <Show when={error()}><p role="alert">{error()}</p></Show>
    <Show when={!loading() && !error() && !hits().length}><p class="pane-empty">No matching pages.</p></Show>
    <ul class="link-list"><For each={hits()}>{(hit) => <li><NoteDestinationLink note={hit.note} relationship={reason(hit)} /></li>}</For></ul>
  </section>
}
