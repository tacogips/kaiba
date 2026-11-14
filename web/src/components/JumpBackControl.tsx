import { type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { WorkspaceIcon } from './WorkspaceIcon'
import './form-controls.css'

/** Shared reader navigation, covering source note/page and explicit pane jumps. */
export function JumpBackControl(): JSX.Element {
  const app = useApp()
  return <button type="button" class="secondary form-icon-button reader-back" aria-label="Jump back" title="Return to the previously viewed page or note"
    disabled={app.state.returnStack.length === 0} onClick={app.goBack}>
    <WorkspaceIcon name="return" />
  </button>
}
