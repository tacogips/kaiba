import { For, Show, createEffect, createMemo, createSignal, type JSX } from 'solid-js'
import { MarkdownBody } from './Markdown'
import { parseNotebookDraft } from '../notes/notebookDraft'
import { createVimTextarea } from '../editor/VimTextarea'
import { LineNumberGutter } from '../editor/LineNumberGutter'
import { useApp, type AppStore } from '../state/appStore'
import { tagTermsFromAssignments } from '../notes/tagMatch'
import { noteHeadingPrefix } from '../notes/toc'

type Writer = Awaited<ReturnType<AppStore['notebookWriter']>>
export function NotebookWritingView(props: { writer: Writer; writing: boolean; readOnly: boolean; onViewport: (element: HTMLElement) => void }): JSX.Element {
  const app = useApp()
  const parsed = createMemo(() => parseNotebookDraft(props.writer.draft.text()))
  const metadata = createMemo(() => {
    const notes = app.notes(), parts = parsed().notes
    const used = new Set<number>()
    const indices = parts.map((part, index) => {
      const samePosition = notes[index]?.bodyMarkdown === part.bodyMarkdown && !used.has(index)
      const match = samePosition ? index : notes.findIndex((note, candidate) => !used.has(candidate) && note.bodyMarkdown === part.bodyMarkdown)
      if (match >= 0) used.add(match)
      return match
    })
    if (parts.length === notes.length) indices.forEach((match, index) => {
      if (match < 0 && !used.has(index)) { indices[index] = index; used.add(index) }
    })
    return indices.map((index) => index >= 0 ? notes[index] : undefined)
  })
  const vim = createVimTextarea({ save: () => { if (!props.readOnly) void props.writer.autosave.flush() } })
  let source!: HTMLTextAreaElement
  const [sourceElement, setSourceElement] = createSignal<HTMLTextAreaElement>()
  const trackNote = () => {
    const cursor = source.selectionStart
    let number = 1
    for (const [index, note] of parsed().notes.entries()) { if (note.startOffset > cursor) break; number = index + 1 }
    props.writer.setCurrentNote(number)
  }
  createEffect(() => { if (props.writing) queueMicrotask(() => source?.focus()) })
  return <div class="reader-body notebook-writing">
    <form class="notebook-writing-form" onSubmit={(event) => { event.preventDefault(); if (!props.readOnly) void props.writer.autosave.flush() }}>
      <div class="notebook-source-frame" hidden={!props.writing}>
        <Show when={props.writing}><LineNumberGutter textarea={sourceElement} text={props.writer.draft.text} /></Show>
        <textarea class="notebook-source" aria-label="Notebook Markdown source" ref={(element) => { source = element; setSourceElement(element); vim.ref(element) }} hidden={!props.writing}
          value={props.writer.draft.text()} readOnly={props.readOnly} disabled={props.readOnly}
          onInput={(event) => { props.writer.draft.setText(event.currentTarget.value); trackNote() }} onClick={trackNote} onKeyUp={trackNote} onSelect={trackNote} spellcheck={false} />
      </div>
      <Show when={!props.writing}><div ref={props.onViewport} class="notebook-source-preview" aria-label="Notebook preview">
        <For each={parsed().notes}>{(note, index) => {
          const stored = () => metadata()[index()]
          return <section class="reader-note" data-note-id={stored()?.noteId} onClick={() => props.writer.setCurrentNote(index() + 1)}>
            <Show when={stored()?.title?.trim()}>{(title) => <header class="reader-note-head"><span class="reader-note-title">{title()}</span></header>}</Show>
            <MarkdownBody markdown={note.bodyMarkdown} anchorPrefix={stored() ? noteHeadingPrefix(stored()!.noteId) : undefined}
              tagTerms={tagTermsFromAssignments([stored()?.tags, app.notebook()?.tags])} onTagClick={app.openTagPane} />
          </section>
        }}</For>
      </div></Show>
      <footer class="notebook-writing-status">
        <Show when={props.writing}><vim.Status /></Show>
        <span>{parsed().notes.length} notes</span>
        <span role="status">{props.writer.autosave.status()}</span>
      </footer>
      <Show when={props.writer.draft.error()}><p role="alert" class="note-inline-error">{props.writer.draft.error()}</p></Show>
    </form>
  </div>
}
