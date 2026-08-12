import { Show, createEffect, createMemo, createSignal, onCleanup, type JSX } from 'solid-js'
import { MarkdownBody } from '../components/Markdown'
import { noteDisplayTitle, noteExportFilename } from '../notes/noteText'
import { useApp } from '../state/appStore'

// Center reader: the selected note rendered as markdown, with page navigation
// through the notebook's notes and heading scroll-sync feeding the Contents tab.

export function ReaderPane(): JSX.Element {
  const app = useApp()
  const [copied, setCopied] = createSignal(false)
  // A signal rather than a plain ref: the body element only exists once the
  // note renders, and the scroll-sync effect has to re-run when it appears.
  const [body, setBody] = createSignal<HTMLElement>()
  let copiedTimer: ReturnType<typeof setTimeout> | undefined

  const notes = createMemo(() => app.notes())
  const index = createMemo(() => notes().findIndex((note) => note.noteId === app.state.noteId))
  const previous = createMemo(() => (index() > 0 ? notes()[index() - 1] : undefined))
  const next = createMemo(() => (index() >= 0 ? notes()[index() + 1] : undefined))

  // The observer is rebuilt per note because the heading elements are replaced
  // whenever the rendered body changes.
  createEffect(() => {
    const note = app.state.note
    const container = body()
    if (!note || !container) return
    const visible = new Map<string, boolean>()
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        const id = entry.target.id
        if (id) visible.set(id, entry.isIntersecting)
      }
      const headings = [...container.querySelectorAll<HTMLElement>('[data-md-heading]')]
      const active = headings.find((heading) => visible.get(heading.id))
        ?? [...headings].reverse().find((heading) => heading.getBoundingClientRect().top < 0)
      if (active?.id) app.setActiveHeading(active.id)
    }, { rootMargin: '0px 0px -70% 0px', threshold: [0, 1] })
    queueMicrotask(() => {
      for (const heading of container.querySelectorAll<HTMLElement>('[data-md-heading]')) {
        if (heading.id) observer.observe(heading)
      }
    })
    onCleanup(() => observer.disconnect())
  })

  const copy = async () => {
    const note = app.state.note
    if (!note) return
    try {
      await navigator.clipboard.writeText(note.bodyMarkdown)
      setCopied(true)
      if (copiedTimer) clearTimeout(copiedTimer)
      copiedTimer = setTimeout(() => setCopied(false), 1500)
    } catch {
      app.setMessage('Could not copy to the clipboard.')
    }
  }

  const download = () => {
    const note = app.state.note
    if (!note) return
    const blob = new Blob([note.bodyMarkdown], { type: 'text/markdown;charset=utf-8' })
    const url = URL.createObjectURL(blob)
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = noteExportFilename(noteDisplayTitle(note))
    anchor.click()
    URL.revokeObjectURL(url)
  }

  onCleanup(() => { if (copiedTimer) clearTimeout(copiedTimer) })

  return (
    <main class="reader" id="main-content" tabindex="-1">
      <Show when={app.state.noteLoading && !app.state.note}>
        <div class="loading-state"><span class="loader" />Loading note…</div>
      </Show>
      <Show
        when={app.state.note}
        fallback={
          <Show when={!app.state.noteLoading}>
            <div class="empty-state">
              <span aria-hidden="true">◇</span>
              <strong>No note open</strong>
              <p>Pick a notebook or note in the Files pane to start reading.</p>
            </div>
          </Show>
        }
      >{(note) => <>
        <header class="reader-head">
          <div class="reader-title">
            <span class="eyebrow">{app.notebook()?.title ?? 'NOTE'}</span>
            <h1>{noteDisplayTitle(note())}</h1>
          </div>
          <div class="reader-actions">
            <Show when={note().readOnly}><span class="note-readonly-badge">Read-only</span></Show>
            <button
              type="button"
              class="secondary"
              aria-label="Previous note"
              disabled={!previous()}
              onClick={() => { const target = previous(); if (target) app.openNote(target.noteId, target.notebookId) }}
            >‹</button>
            <span class="reader-position">{pageLabel(index(), notes().length)}</span>
            <button
              type="button"
              class="secondary"
              aria-label="Next note"
              disabled={!next()}
              onClick={() => { const target = next(); if (target) app.openNote(target.noteId, target.notebookId) }}
            >›</button>
            <button type="button" class="secondary" onClick={() => void copy()}>
              {copied() ? 'Copied' : 'Copy'}
            </button>
            <button type="button" class="secondary" onClick={download}>Download</button>
          </div>
        </header>
        <article class="reader-body" ref={setBody}>
          <MarkdownBody markdown={note().bodyMarkdown} />
        </article>
      </>}</Show>
    </main>
  )
}

function pageLabel(index: number, total: number): string {
  if (index < 0 || total === 0) return ''
  return `${index + 1} / ${total}`
}
