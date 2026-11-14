import type { JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'

/** Every notebook entry point opens the same automatically saved writer. */
export function NotebookCreate(): JSX.Element {
  const app = useApp()
  return <button type="button" title="Start writing a new notebook" onClick={async () => {
    await app.notebookAutosave.startNew()
    app.openHome()
    queueMicrotask(() => document.querySelector<HTMLTextAreaElement>('.new-notebook-editor textarea')?.focus())
  }}><WorkspaceIcon name="edit" />New notebook</button>
}
