import { Show, type JSX } from 'solid-js'
import { documentPageMetadata } from '../notes/documentPages'
import { useApp } from '../state/appStore'
import { PageOCRAction } from './PageOCRAction'

export function DocumentPageOCRControl(): JSX.Element {
  const app = useApp()
  const page = () => app.state.note?.noteId === app.state.noteId ? documentPageMetadata(app.state.note) : undefined
  return <Show when={page()}>{(metadata) => <section class="page-ocr-control" aria-label="Page search text">
    <strong>Page {metadata().pageNumber}</strong>
    <Show when={metadata().textStatus === 'pending'} fallback={<span>Searchable</span>}>
      <p>Text on this page is not searchable yet.</p>
    </Show>
    <PageOCRAction noteId={app.state.noteId!} pageNumber={metadata().pageNumber} complete={metadata().textStatus === 'complete'} />
  </section>}</Show>
}
