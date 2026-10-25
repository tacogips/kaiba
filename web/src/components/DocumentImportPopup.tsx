import { createSignal, onCleanup, onMount, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'
import { routeHref, useApp } from '../state/appStore'
import { DocumentImportForm } from './DocumentImportForm'
import { WorkspaceIcon } from './WorkspaceIcon'
import { usePopoverDismissal } from './usePopoverDismissal'
import './document-import-popup.css'

export function DocumentImportPopup(props: { onClose: () => void }): JSX.Element {
  const app = useApp()
  const [busy, setBusy] = createSignal(false)
  let dialog!: HTMLElement
  onMount(() => {
    const previous = document.activeElement as HTMLElement | null
    dialog.querySelector<HTMLButtonElement>('[title="Choose a PDF or image to import"]')?.focus()
    onCleanup(() => { if (previous?.isConnected) previous.focus() })
  })
  const close = () => { if (!busy()) props.onClose() }
  usePopoverDismissal({ isOpen: () => true, canDismiss: () => !busy(),
    contains: (target) => dialog.contains(target), onDismiss: close,
    dismissOutside: false, captureEscape: false })
  const importDocument = async (file: File, title?: string, maximumOCRPages?: string, textExtractionMode?: string) => {
    const startedRoute = routeHref(app.state.route)
    setBusy(true)
    try {
      const notebook = await app.client.importDocument(file, title, maximumOCRPages, textExtractionMode ?? app.state.settings.pdfTextMode)
      await app.refreshCatalog()
      if (routeHref(app.state.route) === startedRoute) app.openNotebook(notebook.notebookId)
      props.onClose()
    } finally { setBusy(false) }
  }
  return <Portal><div class="note-modal-backdrop document-import-backdrop" role="presentation" onClick={(event) => {
    if (event.target === event.currentTarget) close()
  }}>
    <section ref={dialog} class="document-import-popup" role="dialog" aria-modal="true" aria-label="Import document"
      onKeyDown={(event) => {
        if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close() }
        if (event.key !== 'Tab') return
        const controls = [...dialog.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled):not([tabindex="-1"]), select:not(:disabled), summary')]
          .filter((element) => !element.closest('details:not([open])') || element.tagName === 'SUMMARY')
        const first = controls[0], last = controls[controls.length - 1]
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }}>
      <header><h2>Import document</h2><button type="button" class="import-popup-close" aria-label="Close document import" title="Close import" disabled={busy()} onClick={close}><WorkspaceIcon name="close" /></button></header>
      <DocumentImportForm onImport={importDocument} />
    </section>
  </div></Portal>
}
