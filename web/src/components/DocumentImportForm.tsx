import { Show, createSignal, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'

export function DocumentImportForm(props: {
  onImport: (file: File, title?: string, maximumOCRPages?: string, textExtractionMode?: string) => Promise<void>
}): JSX.Element {
  let picker!: HTMLInputElement
  const [file, setFile] = createSignal<File>()
  const [title, setTitle] = createSignal('')
  const [textMode, setTextMode] = createSignal('')
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
      await props.onImport(selected, title().trim() || undefined, limit() || undefined, textMode() || undefined)
      setFile(undefined)
    } catch (cause) {
      setError(`Import could not be confirmed. Check your notebooks before retrying. ${cause instanceof Error ? cause.message : String(cause)}`)
    } finally {
      setBusy(false)
    }
  }
  return <form class="note-capture document-import-form" aria-label="Import document" onSubmit={(event) => void submit(event)}>
    <p class="document-import-heading">Choose a PDF or image to create a notebook from its pages.</p>
    <input ref={picker} class="sr-only" tabindex="-1" type="file" aria-label="Document file" accept=".pdf,.png,.jpg,.jpeg,.gif,.webp" disabled={busy()}
      onChange={(event) => {
        const selected = event.currentTarget.files?.[0]
        setFile(selected); setTitle(selected?.name ?? ''); setError('')
      }} />
    <button type="button" class="secondary form-action-button" title="Choose a PDF or image to import" disabled={busy()} onClick={() => picker.click()}><WorkspaceIcon name="files" />{file() ? 'Change file' : 'Choose file'}</button>
    <Show when={file()}>{(selected) => <p class="document-import-filename">{selected().name}</p>}</Show>
    <p class="document-import-hint">Browser uploads: PDF or image, up to 1 MiB per file.</p>
    <Show when={file()}>
    <details class="document-import-options"><summary>Import options</summary>
    <label>Name in Kaiba (optional)
      <input aria-label="Name in Kaiba" value={title()} placeholder={file()?.name} disabled={busy()} onInput={(event) => setTitle(event.currentTarget.value)} />
    </label>
    <p class="document-import-hint">This is the notebook name. Leave it blank to use the filename; you can rename it later.</p>
    <label>Text extraction
      <select value={textMode()} disabled={busy()} onChange={(event) => setTextMode(event.currentTarget.value)}>
        <option value="">Use default from Settings</option>
        <option value="prefer-pdf-text">Use PDF text, fall back to OCR</option>
        <option value="ocr-only">OCR only</option>
      </select>
    </label>
    <label>Pages to OCR
      <input value={limit()} placeholder="Server default" disabled={busy()}
        onInput={(event) => setLimit(event.currentTarget.value.trim())} />
    </label>
    <p>Enter 0, a page count, or all. You can recognize more pages later.</p>
    </details>
    <button type="submit" class="form-action-button" aria-label="Import document" title="Import document" aria-busy={busy()} disabled={!file() || busy()}><WorkspaceIcon name="file" />{busy() ? 'Importing…' : 'Import'}</button>
    </Show>
    <Show when={error()}><p role="alert" class="note-inline-error">{error()}</p></Show>
  </form>
}
