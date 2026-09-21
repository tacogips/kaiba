import { Show, createSignal, type JSX } from 'solid-js'

export function DocumentImportForm(props: {
  onImport: (file: File, title?: string, maximumOCRPages?: string) => Promise<void>
}): JSX.Element {
  const [file, setFile] = createSignal<File>()
  const [title, setTitle] = createSignal('')
  const [limit, setLimit] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  const submit = async (event: Event) => {
    event.preventDefault()
    const selected = file()
    if (!selected || busy()) return
    if (!/\.(pdf|png|jpe?g|gif|webp)$/i.test(selected.name) || selected.size === 0 || selected.size > 1_048_576) {
      setError('Choose a PDF or image up to 1 MiB. Larger documents can use the local import command.')
      return
    }
    if (limit() && limit() !== 'all' && !/^\d+$/.test(limit())) {
      setError('OCR pages must be a nonnegative whole number or “all”.')
      return
    }
    setBusy(true)
    setError('')
    try {
      await props.onImport(selected, title().trim() || undefined, limit() || undefined)
      setFile(undefined)
    } catch (cause) {
      setError(`Import could not be confirmed. Check your notebooks before retrying. ${cause instanceof Error ? cause.message : String(cause)}`)
    } finally {
      setBusy(false)
    }
  }
  return <form class="note-capture document-import-form" aria-label="Import document" onSubmit={(event) => void submit(event)}>
    <label>PDF or image (up to 1 MiB)
      <input type="file" accept=".pdf,.png,.jpg,.jpeg,.gif,.webp" disabled={busy()}
        onChange={(event) => { setFile(event.currentTarget.files?.[0]); setError('') }} />
    </label>
    <label>Document title (optional)
      <input value={title()} disabled={busy()} onInput={(event) => setTitle(event.currentTarget.value)} />
    </label>
    <label>Pages to OCR
      <input value={limit()} placeholder="Server default" disabled={busy()}
        onInput={(event) => setLimit(event.currentTarget.value.trim())} />
    </label>
    <p>Enter 0, a page count, or all. Remaining pages keep their originals and can be OCRed individually later.</p>
    <button type="submit" disabled={!file() || busy()}>{busy() ? 'Importing…' : 'Import document'}</button>
    <Show when={error()}><p role="alert" class="note-inline-error">{error()}</p></Show>
  </form>
}
