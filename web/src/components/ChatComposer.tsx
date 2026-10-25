import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import type { AgentModel } from '../notes/types'
import { handleComposerKeyDown } from '../notes/memoComposer'
import { WorkspaceIcon } from './WorkspaceIcon'
import { AgentModelPicker } from './AgentModelPicker'

export interface MemoComposerControlsProps {
  memoOnly: boolean
  noteEdit: boolean
  canNoteEdit: boolean
  busy: boolean
  locked?: boolean
  readOnly?: boolean
  generating?: boolean
  hideModes?: boolean
  autofocus?: boolean
  placeholder?: string
  inputLabel?: string
  sendLabel?: string
  draft: string
  attachments: readonly File[]
  models: readonly AgentModel[]
  selectedModel?: string
  providers?: readonly string[]
  selectedProvider?: string
  onProviderChange?(provider: string): void
  extensionsEnabled: boolean
  onStageFiles(files: FileList | readonly File[] | null): void | Promise<void>
  onToggleMemoOnly(): void
  onToggleNoteEdit(): void
  onDraftChange(value: string): void
  onRemoveAttachment(index: number): void
  onModelChange(model: string, provider?: string): void
  onSubmit(): void
}

/** Shared footer and conversation composer. The server remains the authority
 * for model availability and supported attachment types. */
export function MemoComposerControls(props: MemoComposerControlsProps): JSX.Element {
  let picker: HTMLInputElement | undefined
  let input: HTMLTextAreaElement | undefined
  const [dragging, setDragging] = createSignal(false)
  const locked = () => props.busy || props.locked
  const canAttach = () => props.extensionsEnabled && !locked() && !props.readOnly
  const canSend = () => !locked() && !props.generating && Boolean(props.draft.trim())
  const resize = () => {
    if (!input) return
    input.style.height = 'auto'
    input.style.height = `${Math.min(180, Math.max(input.closest('.agent-footer') ? 76 : 44, input.scrollHeight))}px`
  }
  createEffect(() => { void props.draft; queueMicrotask(resize) })
  createEffect(() => { if (props.autofocus) queueMicrotask(() => input?.focus()) })
  const stage = (files: FileList | readonly File[] | null) => {
    if (canAttach() && files?.length) void props.onStageFiles(Array.from(files))
  }
  return <div class="memo-composer" classList={{ 'composer-dragging': dragging() }}
    onDragOver={(event) => {
      if (event.dataTransfer?.types.includes('Files')) {
        event.preventDefault()
        setDragging(canAttach())
      }
    }}
    onDragLeave={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragging(false) }}
    onDrop={(event) => {
      event.preventDefault()
      setDragging(false)
      stage(event.dataTransfer?.files ?? null)
    }}>
    <input class="sr-only" type="file" multiple tabIndex={-1} ref={picker}
      aria-label="Choose attachments" accept=".txt,.md,.csv,.tsv,.json,.xml,.yaml,.yml,text/plain,text/markdown,text/csv,application/json,image/png,image/jpeg"
      disabled={!canAttach()} onChange={(event) => {
        stage(event.currentTarget.files)
        event.currentTarget.value = ''
      }} />
    <Show when={props.attachments.length > 0}>
      <div class="attachment-chips" aria-label="Attached files">
        <For each={props.attachments}>{(file, index) => <div class="attachment-card">
          <Show when={file.type.startsWith('image/')} fallback={<WorkspaceIcon name="file" />}><AttachmentThumbnail file={file} /></Show>
          <span class="attachment-description"><strong title={file.name}>{file.name}</strong>
            <small>{Math.max(1, Math.ceil(file.size / 1024))} KB · {file.type.startsWith('image/') ? 'Image' : 'Text'}</small></span>
          <button type="button" aria-label={`Remove ${file.name}`} title={`Remove ${file.name}`}
            disabled={locked() || props.readOnly} onClick={() => props.onRemoveAttachment(index())}><WorkspaceIcon name="close" /></button>
        </div>}</For>
      </div>
    </Show>
    <div class="composer-main">
      <textarea ref={input} aria-label={props.inputLabel ?? 'New memo or agent message'} rows={2}
        value={props.draft} disabled={locked()} readOnly={props.readOnly}
        onInput={(event) => props.onDraftChange(event.currentTarget.value)}
        onPaste={(event) => {
          if (event.clipboardData?.files.length) { event.preventDefault(); stage(event.clipboardData.files) }
        }}
        onKeyDown={(event) => handleComposerKeyDown(event, {
          busy: Boolean(locked() || props.generating), hasDraft: Boolean(props.draft.trim()),
        }, props.onSubmit)} />
    </div>
    <div class="composer-toolbar">
      <button type="button" class="composer-icon" title="Attach text files or images"
        aria-label="Attach text files or images" aria-disabled={!canAttach()} disabled={!canAttach()} onClick={() => picker?.click()}><WorkspaceIcon name="add" /></button>
      <AgentModelPicker models={props.models} selectedModel={props.selectedModel} selectedProvider={props.selectedProvider}
        disabled={!props.extensionsEnabled || locked() || Boolean(props.readOnly) || props.models.length === 0}
        onSelect={props.onModelChange} />
      <Show when={!props.hideModes}>
        <details class="composer-options">
          <summary aria-label="Chat options" title="Chat options"><WorkspaceIcon name="more" /></summary>
          <div class="composer-options-menu">
            <button type="button" aria-label="Memo only" title="Memo only" aria-pressed={props.memoOnly} disabled={locked()} onClick={props.onToggleMemoOnly}>Memo only</button>
            <button type="button" aria-label="Edit note mode" aria-pressed={props.noteEdit}
              aria-disabled={!props.canNoteEdit && !props.noteEdit}
              title={props.canNoteEdit || props.noteEdit ? 'Edit note mode' : 'Note edit mode requires a writable note'}
              disabled={locked() || (!props.canNoteEdit && !props.noteEdit)} onClick={props.onToggleNoteEdit}>Edit note mode</button>
          </div>
        </details>
      </Show>
      <button type="button" class="composer-submit" aria-label={props.sendLabel ?? (props.memoOnly ? 'Save memo' : 'Send message')}
        title={props.generating ? 'Waiting for the current reply' : props.busy ? 'Sending…' : 'Send (Enter) · New line (Shift+Enter)'}
        disabled={!canSend()} onClick={props.onSubmit}>
        <Show when={props.busy || props.generating} fallback={<WorkspaceIcon name={props.memoOnly ? 'save' : 'send'} />}>
          <span class="composer-working" aria-label={props.busy ? 'Sending' : 'Reply in progress'} />
        </Show>
      </button>
    </div>
    <Show when={props.memoOnly || props.noteEdit}><span class="composer-active-mode">{props.memoOnly ? 'Memo only' : 'Editing note'}</span></Show>
  </div>
}

function AttachmentThumbnail(props: { file: File }): JSX.Element {
  const [url, setURL] = createSignal('')
  createEffect(() => {
    const value = URL.createObjectURL(props.file)
    setURL(value)
    onCleanup(() => URL.revokeObjectURL(value))
  })
  return <img class="attachment-thumbnail" src={url()} alt={props.file.name} />
}
