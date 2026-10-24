import { For, Show, createEffect, createResource, createSignal, on, onCleanup, onMount, type JSX } from 'solid-js'
import type { NoteId, NotebookId } from '../notes/ids'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'
import './document-versions.css'

export interface DocumentTranslationVersion {
  noteId: NoteId
  notebookId: NotebookId
  targetLanguage: string
  text: string
  sourceNoteId?: NoteId
}
export type DocumentDisplayMode = 'original' | 'text' | 'translation'

export function DocumentVersionsControl(props: {
  notebookId: NotebookId
  sourceNoteId: NoteId
  pageNumber: number
  totalPages: number
  displayMode: DocumentDisplayMode
  selectedTranslationId?: NoteId
  preferredTranslationLanguage?: string
  onSelect: (mode: DocumentDisplayMode, translation?: DocumentTranslationVersion) => void
}): JSX.Element {
  const app = useApp()
  const [open, setOpen] = createSignal(false)
  const [language, setLanguage] = createSignal('')
  const [scope, setScope] = createSignal<'current' | 'range' | 'all'>('current')
  const [start, setStart] = createSignal('')
  const [end, setEnd] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [status, setStatus] = createSignal('')
  const [failure, setFailure] = createSignal('')
  const [loadFailure, setLoadFailure] = createSignal('')
  let container!: HTMLDivElement
  let trigger!: HTMLButtonElement
  let desiredLanguage = ''
  let adoptedVersion: DocumentTranslationVersion | undefined
  const [versions] = createResource(
    () => ({ noteId: props.sourceNoteId, revision: app.state.catalogRevision }),
    async ({ noteId }): Promise<DocumentTranslationVersion[]> => {
      setLoadFailure('')
      try {
        const result = await app.client.documentPageTranslations(noteId)
        return result.map((version) => ({ ...version, sourceNoteId: version.sourceNoteId ?? noteId }))
      }
      catch (error) {
        if (noteId === props.sourceNoteId) setLoadFailure(error instanceof Error ? error.message : String(error))
        return []
      }
    },
  )
  const availableVersions = () => versions.loading ? [] : (versions() ?? []).filter((version) => version.sourceNoteId === props.sourceNoteId)
  const selected = () => availableVersions().find((version) => version.noteId === props.selectedTranslationId) ?? availableVersions()[0]
  const chooseTranslation = (version: DocumentTranslationVersion | undefined) => {
    desiredLanguage = version?.targetLanguage ?? desiredLanguage
    adoptedVersion = version
    props.onSelect('translation', version)
  }
  createEffect(on(() => [versions(), versions.loading, props.displayMode, props.sourceNoteId, props.selectedTranslationId] as const,
    ([items, loading, mode, sourceNoteId, selectedId]) => {
      if (loading || !items || mode !== 'translation') return
      const current = items.filter((version) => version.sourceNoteId === sourceNoteId)
      const preferredLanguage = props.preferredTranslationLanguage ?? desiredLanguage
      const next = current.find((version) => version.noteId === selectedId)
        ?? current.find((version) => version.targetLanguage === preferredLanguage) ?? current[0]
      if (!next) {
        if (selectedId) chooseTranslation(undefined)
        return
      }
      // Refresh changed text after a catalog event, while a controlled parent
      // updating its selected ID must not cause a second selection loop.
      if (next.noteId !== selectedId || adoptedVersion?.noteId !== next.noteId
        || adoptedVersion?.sourceNoteId !== sourceNoteId || adoptedVersion?.text !== next.text) chooseTranslation(next)
    }))
  const validRange = () => /^\d+$/.test(start()) && /^\d+$/.test(end())
    && Number(start()) >= 1 && Number(end()) >= Number(start()) && Number(end()) <= props.totalPages
  const close = () => { setOpen(false); trigger.focus() }
  createEffect(on(() => [props.pageNumber, props.sourceNoteId] as const, ([page]) => {
    setStart(String(page))
    setEnd(String(page))
    setStatus('')
    setFailure('')
    setOpen(false)
  }))
  onMount(() => {
    const dismiss = (event: PointerEvent) => {
      if (open() && event.target instanceof Node && !container.contains(event.target)) setOpen(false)
    }
    document.addEventListener('pointerdown', dismiss)
    onCleanup(() => document.removeEventListener('pointerdown', dismiss))
  })
  const translate = async (event: Event) => {
    event.preventDefault()
    if (busy() || !language().trim() || (scope() === 'range' && !validRange())) return
    const sourceNoteId = props.sourceNoteId
    const range = scope() === 'current' ? { pageStart: props.pageNumber, pageEnd: props.pageNumber }
      : scope() === 'range' ? { pageStart: Number(start()), pageEnd: Number(end()) } : {}
    setBusy(true)
    setStatus('')
    setFailure('')
    try {
      const result = await app.client.requestNotebookTranslation({
        notebookId: props.notebookId, targetLanguage: language().trim(), ...range,
      })
      if (sourceNoteId !== props.sourceNoteId) return
      setStatus(result.status === 'queued'
        ? 'Translation queued. Translated pages appear here when ready.'
        : 'Agent runtime not configured, so translation was not queued.')
    } catch (error) {
      if (sourceNoteId === props.sourceNoteId) setFailure(error instanceof Error ? error.message : String(error))
    } finally { setBusy(false) }
  }
  return <div class="document-versions-control" ref={container} onKeyDown={(event) => {
    if (event.key === 'Escape' && open()) { event.stopPropagation(); close() }
  }}>
    <div class="document-version-switch" role="group" aria-label="Page display">
      <button type="button" class="secondary" aria-pressed={props.displayMode === 'original'} onClick={() => props.onSelect('original')}>Original</button>
      <button type="button" class="secondary" aria-pressed={props.displayMode === 'text'} onClick={() => props.onSelect('text')}>OCR</button>
      <button type="button" class="secondary" aria-pressed={props.displayMode === 'translation'} disabled={!selected() || versions.loading}
        title={selected() ? `Translated: ${selected()!.targetLanguage}` : 'No translation for this page'}
        onClick={() => chooseTranslation(selected())}>Translated</button>
    </div>
    <Show when={props.displayMode === 'translation' && availableVersions().length > 1}>
      <select class="document-translation-language" aria-label="Translation language" title={selected()?.targetLanguage}
        value={selected()?.noteId} onChange={(event) => {
          const version = availableVersions().find((item) => item.noteId === event.currentTarget.value)
          if (version) chooseTranslation(version)
        }}>
        <For each={availableVersions()}>{(version) => <option value={version.noteId}>{version.targetLanguage}</option>}</For>
      </select>
    </Show>
    <button type="button" class="secondary form-icon-button" ref={trigger} aria-label="Translate pages" title="Translate pages"
      aria-expanded={open()} aria-controls="document-translation-options" onClick={() => setOpen(!open())}>
      <WorkspaceIcon name="translate" />
    </button>
    <Show when={open()}>
      <section class="document-translation-popover" id="document-translation-options" aria-label="Translate pages">
        <form onSubmit={(event) => void translate(event)}>
          <label>Target language<input autofocus value={language()} placeholder="e.g. English" disabled={busy()}
            onInput={(event) => setLanguage(event.currentTarget.value)} /></label>
          <label>Pages<select aria-label="Pages to translate" value={scope()} disabled={busy()}
            onChange={(event) => setScope(event.currentTarget.value as 'current' | 'range' | 'all')}>
            <option value="current">Current page ({props.pageNumber})</option>
            <option value="range">Page range</option>
            <option value="all">Whole document</option>
          </select></label>
          <Show when={scope() === 'range'}>
            <div class="document-translation-range">
              <label>From<input type="number" aria-label="First page" min="1" max={props.totalPages} value={start()} disabled={busy()}
                onInput={(event) => setStart(event.currentTarget.value)} /></label>
              <label>To<input type="number" aria-label="Last page" min="1" max={props.totalPages} value={end()} disabled={busy()}
                onInput={(event) => setEnd(event.currentTarget.value)} /></label>
            </div>
            <Show when={!validRange()}><p role="alert">Choose a range from 1 to {props.totalPages}.</p></Show>
          </Show>
          <button type="submit" class="form-action-button" aria-label="Request translation" title="Request translation" aria-busy={busy()}
            disabled={busy() || !language().trim() || (scope() === 'range' && !validRange())}>
            <WorkspaceIcon name="check" />{busy() ? 'Requesting…' : 'Translate'}
          </button>
          <Show when={status()}><p role="status">{status()}</p></Show>
          <Show when={failure()}><p role="alert">{failure()}</p></Show>
          <Show when={loadFailure()}><p role="alert">Translations could not be loaded: {loadFailure()}</p></Show>
        </form>
      </section>
    </Show>
  </div>
}
