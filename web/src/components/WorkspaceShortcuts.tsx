import { For, onCleanup, onMount, type JSX } from 'solid-js'
import { WorkspaceIcon } from './WorkspaceIcon'

export interface WorkspaceCommand {
  label: string
  key: string
  shift?: boolean
  run: () => void
}

export function shortcutLabel(command: Pick<WorkspaceCommand, 'key' | 'shift'>): string {
  return `⌘/Ctrl ${command.shift ? 'Shift ' : ''}${command.key.toUpperCase()}`
}

/** Shared commands keep keyboard behavior and the visible reference in sync. */
export function WorkspaceShortcuts(props: {
  commands: WorkspaceCommand[]
  blocked: () => boolean
}): JSX.Element {
  let dialog!: HTMLDialogElement
  onMount(() => {
    const handle = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.repeat || event.altKey
        || !(event.metaKey || event.ctrlKey) || props.blocked() || dialog.open
        || document.querySelector('dialog[open], [role="dialog"]')) return
      const key = event.code.startsWith('Digit') ? event.code.slice(5) : event.key.toLowerCase()
      const command = props.commands.find((item) => item.key === key
        && Boolean(item.shift) === event.shiftKey)
      if (!command) return
      event.preventDefault()
      command.run()
    }
    window.addEventListener('keydown', handle)
    onCleanup(() => window.removeEventListener('keydown', handle))
  })
  return <>
    <button type="button" class="workspace-icon" aria-label="Keyboard shortcuts" title="Keyboard shortcuts"
      onClick={() => dialog.showModal()}><WorkspaceIcon name="keyboard" /></button>
    <dialog ref={dialog} class="keyboard-reference" aria-label="Keyboard shortcuts">
      <h2>Keyboard shortcuts</h2>
      <dl>
        <For each={props.commands}>{(command) => <><dt>{command.label}</dt><dd><kbd>{shortcutLabel(command)}</kbd></dd></>}</For>
        <dt>Send chat message</dt><dd><kbd>Enter</kbd></dd>
        <dt>New line in chat</dt><dd><kbd>Shift Enter</kbd></dd>
        <dt>Close dialog</dt><dd><kbd>Escape</kbd></dd>
      </dl>
      <p>Use Command on macOS or Control on other platforms. Tab and Shift Tab reach individual controls; Enter or Space activates them.</p>
      <button type="button" onClick={() => dialog.close()}>Close</button>
    </dialog>
  </>
}
