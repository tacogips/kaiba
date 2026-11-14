import { Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import type { FileId } from '../notes/ids'
import { useApp } from '../state/appStore'

/** Only the authenticated client fetches file bytes. Each displayed image owns
 * its object URL and discards late responses after navigation or unmount. */
export function NoteFileImage(props: { fileId: FileId; alt: string }): JSX.Element {
  const app = useApp()
  const [url, setURL] = createSignal<string>()
  const [failed, setFailed] = createSignal(false)
  const [retry, setRetry] = createSignal(0)
  createEffect(() => {
    const id = props.fileId
    retry()
    let disposed = false
    let objectURL: string | undefined
    setURL(undefined)
    setFailed(false)
    void app.client.noteFileBlob(id).then((blob) => {
      if (disposed) return
      if (!blob.type.startsWith('image/')) throw new Error('The file is not an image')
      objectURL = URL.createObjectURL(blob)
      setURL(objectURL)
    }).catch(() => { if (!disposed) setFailed(true) })
    onCleanup(() => {
      disposed = true
      if (objectURL) URL.revokeObjectURL(objectURL)
    })
  })
  return <Show when={url()} fallback={
    <span class="document-image-status" role="status">
      {failed() ? 'Image could not be loaded. ' : 'Loading image…'}
      <Show when={failed()}><button type="button" class="secondary" onClick={() => setRetry((value) => value + 1)}>Retry image</button></Show>
    </span>
  }>{(value) => <img class="document-file-image" src={value()} alt={props.alt} draggable={false}
    onError={() => { setURL(undefined); setFailed(true) }} />}</Show>
}
