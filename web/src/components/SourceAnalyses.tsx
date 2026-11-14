import { For, Show, createSignal, onCleanup, type JSX } from 'solid-js'
import { notebookPageLimit } from '../notes/client'
import { analysisPrompt, analysisTemplates } from '../notes/analysisTemplates'
import { newIdempotencyKey } from '../notes/chatState'
import type { NoteId, NotebookId } from '../notes/ids'
import type { Note } from '../notes/types'
import { noteDisplayTitle } from '../notes/noteText'
import { serializeWebSettings } from '../notes/settings'
import { errorMessage, type AppStore } from '../state/appStore'
import '../source-analyses.css'

interface Submission {
  source: Note
  status: string
  conversationId?: NotebookId
}

/** Each mounted panel belongs to one document notebook. Navigation disposes
 * the panel and prevents the batch from submitting any further requests. */
export function SourceAnalyses(props: { app: AppStore; notebookId: NotebookId }): JSX.Element {
  const [open, setOpen] = createSignal(false)
  const [sources, setSources] = createSignal<Note[]>([])
  const [loaded, setLoaded] = createSignal(false)
  const [loading, setLoading] = createSignal(false)
  const [selected, setSelected] = createSignal<NoteId[]>([])
  const [templateId, setTemplateId] = createSignal('summary')
  const [name, setName] = createSignal('')
  const [prompt, setPrompt] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const [submissions, setSubmissions] = createSignal<Submission[]>([])
  let disposed = false
  onCleanup(() => { disposed = true })

  const templates = () => [...analysisTemplates, ...(props.app.state.settings.analysisTemplates ?? [])]
  const template = () => templateId() === 'custom'
    ? { name: name().trim() || 'Custom analysis', prompt: prompt().trim() }
    : templates().find((item) => item.id === templateId())

  const load = async () => {
    if (loaded() || loading()) return
    setLoading(true)
    setError('')
    try {
      const all: Note[] = []
      const seen = new Set<NoteId>()
      let page: Note[]
      do {
        page = await props.app.client.notes(props.notebookId, all.length)
        if (disposed) return
        if (page.length && page.every((note) => seen.has(note.noteId))) {
          throw new Error('The source list changed while loading. Reload sources to try again.')
        }
        for (const note of page) seen.add(note.noteId)
        all.push(...page)
      } while (page.length === notebookPageLimit)
      setSources([...new Map(all.map((note) => [note.noteId, note])).values()])
      setLoaded(true)
      const current = props.app.state.noteId
      setSelected(current && all.some((note) => note.noteId === current) ? [current] : [])
    } catch (failure) {
      if (!disposed) setError(errorMessage(failure))
    } finally {
      if (!disposed) setLoading(false)
    }
  }

  const saveTemplate = () => {
    if (!name().trim() || !prompt().trim()) return
    const saved = props.app.state.settings.analysisTemplates ?? []
    if (saved.length >= 50) { setError('Remove a saved template before adding another (maximum 50).'); return }
    const next = { id: newIdempotencyKey(), name: name().trim(), prompt: prompt().trim() }
    const settings = { ...props.app.state.settings, analysisTemplates: [...saved, next] }
    if (new TextEncoder().encode(serializeWebSettings(settings)).byteLength > 60 * 1024) {
      setError('Saved templates are full. Shorten the instructions or remove a template before saving.')
      return
    }
    setError('')
    props.app.updateSettings({ analysisTemplates: [...saved, next] })
    setTemplateId(next.id)
  }

  const apply = async () => {
    const chosen = template()
    if (busy() || !chosen?.prompt || selected().length === 0) return
    const rows = sources().filter((source) => selected().includes(source.noteId))
      .map((source): Submission => ({ source, status: 'Waiting to submit' }))
    // Snapshot preferences and instructions once so a settings/navigation change
    // during an await cannot alter the remainder of this batch.
    const userMarkdown = analysisPrompt(chosen)
    const model = props.app.state.settings.agentModel
    const provider = props.app.state.settings.agentProvider
    setBusy(true)
    setError('')
    setSubmissions(rows)
    try {
      for (let index = 0; index < rows.length; index += 1) {
        if (disposed) return
        const row = rows[index]!
        setSubmissions((current) => current.map((item, position) => position === index ? { ...item, status: 'Submitting' } : item))
        let outcome: Submission
        try {
          const result = await props.app.client.sendAgentChatMessage({
            subjectNoteId: row.source.noteId,
            userMarkdown, model, provider, idempotencyKey: newIdempotencyKey(),
          })
          outcome = {
            ...row,
            status: result.agentStatus === 'queued' || result.agentStatus === 'pending'
              ? 'Submitted — open the result to follow progress'
              : `Submitted — agent status: ${result.agentStatus}`,
            conversationId: result.conversationNotebookId ?? undefined,
          }
        } catch (failure) {
          outcome = { ...row, status: `Submission not confirmed: ${errorMessage(failure)}. Check source discussions before submitting again.` }
        }
        if (disposed) return
        setSubmissions((current) => current.map((item, position) => position === index ? outcome : item))
      }
    } finally {
      if (!disposed) {
        setBusy(false)
        void props.app.refreshCatalog()
      }
    }
  }

  return <section class="source-analyses" aria-label="Source analyses">
    <button type="button" class="secondary" aria-expanded={open()} onClick={() => {
      setOpen(!open())
      if (open()) void load()
    }}>Analyses</button>
    <Show when={open()}>
      <div class="source-analyses-body">
        <p>Apply a reusable analysis to selected notes. Each result is saved as a separate source-linked discussion.</p>
        <Show when={busy()}><p role="status">Leaving this notebook stops further submissions. Already submitted analyses continue on the server.</p></Show>
        <label>Analysis template
          <select aria-label="Analysis template" value={templateId()} disabled={busy()}
            onChange={(event) => setTemplateId(event.currentTarget.value)}>
            <For each={templates()}>{(item) => <option value={item.id}>{item.name}</option>}</For>
            <option value="custom">Custom analysis</option>
          </select>
        </label>
        <Show when={templateId() === 'custom'} fallback={<p class="analysis-instructions">{template()?.prompt}</p>}>
          <label>Template name<input aria-label="Template name" maxLength={100} value={name()} disabled={busy()}
            onInput={(event) => setName(event.currentTarget.value)} /></label>
          <label>Analysis instructions<textarea aria-label="Analysis instructions" maxLength={10000} rows={4}
            value={prompt()} disabled={busy()} onInput={(event) => setPrompt(event.currentTarget.value)} /></label>
          <p>Saved templates are shared by clients using this store.</p>
          <button type="button" class="secondary" disabled={busy() || !name().trim() || !prompt().trim()}
            onClick={saveTemplate}>Save template</button>
        </Show>
        <Show when={props.app.state.settings.analysisTemplates?.some((item) => item.id === templateId())}>
          <button type="button" class="secondary" disabled={busy()} onClick={() => {
            props.app.updateSettings({ analysisTemplates: props.app.state.settings.analysisTemplates?.filter((item) => item.id !== templateId()) })
            setTemplateId('summary')
          }}>Remove template</button>
        </Show>
        <p>Provider: {props.app.state.settings.agentProvider ?? 'Server default'} · Model: {props.app.state.settings.agentModel ?? 'Server default'}. Change these in the AI composer.</p>
        <Show when={loading()}><p role="status">Loading source notes…</p></Show>
        <Show when={error()}><p role="alert">{error()}</p></Show>
        <Show when={!loaded() && !loading()}><button type="button" onClick={() => void load()}>Reload sources</button></Show>
        <Show when={loaded()}>
          <fieldset disabled={busy()}>
            <legend>Source notes ({selected().length} selected)</legend>
            <button type="button" class="secondary" onClick={() => setSelected(sources().map((note) => note.noteId))}>Select all</button>
            <button type="button" class="secondary" onClick={() => setSelected([])}>Clear selection</button>
            <div class="analysis-sources">
              <For each={sources()} fallback={<p>No source notes.</p>}>{(note) => <label>
                <input type="checkbox" checked={selected().includes(note.noteId)} onChange={(event) => {
                  setSelected((current) => event.currentTarget.checked ? [...current, note.noteId] : current.filter((id) => id !== note.noteId))
                }} />
                <span>{note.noteNumber}. {noteDisplayTitle(note)}</span>
              </label>}</For>
            </div>
          </fieldset>
        </Show>
        <button type="button" class="secondary" disabled={busy() || !loaded() || !selected().length || !template()?.prompt}
          onClick={() => void apply()}>{busy() ? 'Submitting analyses…' : 'Apply to selected notes'}</button>
        <Show when={submissions().length}>
          <ul aria-label="Analysis submissions" aria-live="polite">
            <For each={submissions()}>{(row) => <li>
              <span>{row.source.noteNumber}. {noteDisplayTitle(row.source)}: {row.status} </span>
              <Show when={row.conversationId}>{(id) => <button type="button" class="secondary"
                onClick={() => props.app.openNotebook(id())}>Open result</button>}</Show>
            </li>}</For>
          </ul>
        </Show>
      </div>
    </Show>
  </section>
}
