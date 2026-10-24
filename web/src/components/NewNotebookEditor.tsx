import { For, Show, createMemo, createSignal, createUniqueId, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { parseNotebookDraft } from '../notes/notebookDraft'
import { MarkdownBody } from './Markdown'
import { WorkspaceIcon } from './WorkspaceIcon'
import './notebook-compose.css'

export function NewNotebookEditor(): JSX.Element {
  const app = useApp()
  const draft = app.writingDrafts.get('new-notebook-body')
  const autosave = app.notebookAutosave
  const parsed = createMemo(() => parseNotebookDraft(draft.text()))
  const [mode, setMode] = createSignal<'write' | 'preview'>('write')
  const [activeNote, setActiveNote] = createSignal(0)
  const id = createUniqueId()
  const locked = () => autosave.deleting()
  const words = () => parsed().notes.reduce((total, note) => total + (note.bodyMarkdown.match(/\S+/g)?.length ?? 0), 0)
  let input: HTMLTextAreaElement | undefined
  let preview: HTMLDivElement | undefined
  const trackCursor = () => {
    const cursor = input?.selectionStart ?? 0
    let index = 0
    for (const [position, note] of parsed().notes.entries()) {
      if (note.startOffset > cursor) break
      index = position
    }
    setActiveNote(index)
  }
  const selectNote = (index: number) => {
    setActiveNote(index)
    if (mode() === 'preview') { preview?.querySelector<HTMLElement>(`[data-draft-note="${index}"]`)?.scrollIntoView({ block: 'start' }); return }
    input?.focus()
    const offset = parsed().notes[index]?.startOffset ?? 0
    input?.setSelectionRange(offset, offset)
    if (input) {
      const line = draft.text().slice(0, offset).split('\n').length - 1
      input.scrollTop = Math.max(0, line * (Number.parseFloat(getComputedStyle(input).lineHeight) || 24) - 24)
    }
  }
  const addNote = () => {
    if (locked() || parsed().fenceOpen) return
    const last = parsed().notes.at(-1)!
    if (last.bodyMarkdown.trim()) {
      const source = draft.text()
      draft.setText(`${source}${source.endsWith('\n\n') ? '' : source.endsWith('\n') ? '\n' : '\n\n'}<--->\n\n`)
    }
    setMode('write'); setActiveNote(parsed().notes.length - 1)
    queueMicrotask(() => {
      input?.focus(); input?.setSelectionRange(draft.text().length, draft.text().length)
      if (input) input.scrollTop = input.scrollHeight
    })
  }
  return <div class="reader-body new-notebook-editor notebook-compose">
    <form class="compose-form" aria-label="New notebook" onSubmit={(event) => { event.preventDefault(); void autosave.flush() }}>
      <header class="compose-topbar">
        <div class="compose-breadcrumb"><WorkspaceIcon name="file" /><span>{autosave.notebook() ? 'Notebook' : 'New notebook'}</span></div>
        <div class="compose-top-actions">
          <span class="compose-save-status" role="status" aria-live="polite" aria-atomic="true">
            <Show when={autosave.status() === 'Saved'}><WorkspaceIcon name="check" /></Show>{autosave.status()}
          </span>
          <details class="reader-tools compose-tools">
            <summary aria-label="Notebook menu" title="Notebook menu"><WorkspaceIcon name="more" /></summary>
            <div class="reader-tools-body">
              <button type="button" disabled={autosave.deleting() || (!draft.text() && !autosave.notebook())}
                onClick={(event) => { event.currentTarget.closest('details')?.removeAttribute('open'); void autosave.remove() }}>Delete notebook</button>
            </div>
          </details>
        </div>
      </header>
      <div class="compose-workspace">
        <aside class="compose-outline" aria-label="Draft notes">
          <header><span>Notes <small>{parsed().notes.length}</small></span>
            <button type="button" class="compose-icon" aria-label="Add a note to this draft" title={parsed().fenceOpen ? 'Close the code block before adding a note' : 'Add a note with a <---> separator'}
              disabled={locked() || parsed().fenceOpen} onClick={addNote}><WorkspaceIcon name="add" /></button></header>
          <ol><For each={parsed().notes}>{(note, index) => <li><button type="button" classList={{ 'compose-note-entry': true, active: activeNote() === index() }}
            aria-current={activeNote() === index() ? 'true' : undefined} title={note.title || 'Untitled note'} onClick={() => selectNote(index())}>
            <span class="compose-note-number">{index() + 1}</span><span>{note.title || 'Untitled note'}</span>
          </button></li>}</For></ol>
          <p class="compose-outline-hint">One notebook.<br />Separate notes.</p>
        </aside>
        <section class="compose-document" aria-label="Notebook Markdown">
          <header class="compose-document-head">
            <h1 title={parsed().title || 'Untitled notebook'} classList={{ 'compose-title-empty': !parsed().title }}>{parsed().title || 'Untitled notebook'}</h1>
            <div class="compose-modes" role="group" aria-label="Editor mode">
              <button type="button" title="Write Markdown" aria-pressed={mode() === 'write'} onClick={() => setMode('write')}><WorkspaceIcon name="edit" />Write</button>
              <button type="button" title="Preview the separate notes" aria-pressed={mode() === 'preview'} onClick={() => setMode('preview')}><WorkspaceIcon name="preview" />Preview</button>
            </div>
          </header>
          <Show when={mode() === 'write'} fallback={<div class="compose-preview" ref={preview} aria-label="Notebook preview">
            <For each={parsed().notes}>{(note, index) => <section class="compose-preview-note" data-draft-note={index()}>
              <div class="compose-preview-label">Note {index() + 1}</div>
              <Show when={note.bodyMarkdown} fallback={<p class="compose-empty-note">Empty note</p>}><MarkdownBody markdown={note.bodyMarkdown} /></Show>
            </section>}</For>
          </div>}>
            <div class="compose-source">
              <textarea ref={input} aria-label="Write a new notebook" aria-describedby={`${id}-help`} spellcheck={false}
                value={draft.text()} disabled={locked()} onInput={(event) => { draft.setText(event.currentTarget.value); trackCursor() }}
                onClick={trackCursor} onKeyUp={trackCursor} onSelect={trackCursor} />
              <Show when={!draft.text()}><div class="compose-empty-guide" aria-hidden="true"><strong>Your notebook starts here</strong>
                <p>First line: notebook title.</p><p>Write in Markdown. Add <code>{'<--->'}</code> on its own line to begin the next note.</p></div></Show>
            </div>
          </Show>
        </section>
      </div>
      <footer class="compose-statusbar">
        <span>{parsed().notes.length} {parsed().notes.length === 1 ? 'note' : 'notes'} <span class="compose-status-dot">·</span> {words()} words</span>
        <span id={`${id}-help`}>First line names the notebook. <kbd>{'<--->'}</kbd> starts the next note.</span>
      </footer>
      <Show when={draft.error()}><p class="compose-error" role="alert">{draft.error()}</p></Show>
    </form>
  </div>
}
