import { latestConversationId } from './memoTimeline'
import type { AgentChatAttachmentInput, AgentConversation, AgentModel } from './types'

const allowedTypes = new Set([
  'text/plain', 'text/markdown', 'text/csv', 'text/tab-separated-values',
  'application/json', 'application/xml', 'application/yaml', 'application/x-yaml',
])

const extensions: Record<string, string> = {
  txt: 'text/plain', md: 'text/markdown', csv: 'text/csv', tsv: 'text/tab-separated-values',
  json: 'application/json', xml: 'application/xml', yaml: 'application/yaml', yml: 'application/x-yaml',
}

export function composerShouldSubmit(event: { key: string; shiftKey: boolean; isComposing: boolean }): boolean {
  return event.key === 'Enter' && !event.shiftKey && !event.isComposing
}

/** The component consumes this outcome directly, so keyboard tests cover the
 * same submit/prevent-default decision used by the rendered composer. */
export function composerKeyDownAction(
  event: { key: string; shiftKey: boolean; isComposing: boolean },
  options: { busy: boolean; hasDraft: boolean },
): 'submit' | 'none' {
  return composerShouldSubmit(event) && !options.busy && options.hasDraft ? 'submit' : 'none'
}

/** Production event bridge for the textarea. This keeps `preventDefault` and
 * submission coupled so Enter never also inserts an unintended newline. */
export function handleComposerKeyDown(
  event: { key: string; shiftKey: boolean; isComposing: boolean; preventDefault: () => void },
  options: { busy: boolean; hasDraft: boolean },
  submit: () => void,
): boolean {
  if (composerKeyDownAction(event, options) !== 'submit') return false
  event.preventDefault()
  submit()
  return true
}

/** Attachment, model, and note-edit controls apply to agent sends only, so
 * they rest while memo-only is on or a submit is in flight. */
export function agentComposerExtensionsEnabled(memoOnly: boolean, busy: boolean): boolean {
  return !memoOnly && !busy
}

export function canEnableMemoOnly(stagedAttachmentCount: number): boolean {
  return stagedAttachmentCount === 0
}

export function memoOnlyToggleResult(
  selected: boolean,
  stagedAttachmentCount: number,
  noteEdit = false,
): { selected: boolean; error: string } {
  if (!selected && !canEnableMemoOnly(stagedAttachmentCount)) {
    return { selected, error: 'Remove attached files before enabling memo-only mode.' }
  }
  if (!selected && noteEdit) {
    return { selected, error: 'Disable note edit mode before enabling memo-only mode.' }
  }
  return { selected: !selected, error: '' }
}

/** Note edit mode is only offered where the server's `updateNoteBody` gate
 * would accept the write: a note subject whose own read-only flag and whose
 * notebook's flag are both clear (imported documents lock the notebook). */
export function canEnableNoteEdit(
  subject: { kind: 'note' | 'notebook'; id: string } | undefined,
  note: { noteId: string; readOnly: boolean } | undefined,
  notebook: { readOnly: boolean } | undefined,
): boolean {
  return subject?.kind === 'note' && note?.noteId === subject.id
    && !note.readOnly && notebook !== undefined && !notebook.readOnly
}

export function noteEditToggleResult(
  selected: boolean,
  options: { canEdit: boolean; memoOnly: boolean },
): { selected: boolean; error: string } {
  if (!selected && !options.canEdit) {
    return { selected, error: 'Note edit mode requires a writable note.' }
  }
  if (!selected && options.memoOnly) {
    return { selected, error: 'Disable memo-only mode before enabling note edit mode.' }
  }
  return { selected: !selected, error: '' }
}

export function noteEditControlAttributes(selected: boolean): {
  ariaPressed: boolean
  ariaLabel: string
  title: string
} {
  return { ariaPressed: selected, ariaLabel: 'Edit note mode', title: 'Edit note mode' }
}

export function resetComposerForNewChat<T>(): {
  newConversation: true
  draft: ''
  attachments: T[]
  error: ''
} {
  return { newConversation: true, draft: '', attachments: [], error: '' }
}

export interface AgentChatComposerRequestOptions {
  subject: { kind: 'note' | 'notebook'; id: string }
  conversations: AgentConversation[]
  /** The conversation selected by a completed New chat boundary. */
  activeConversationId?: string
  newConversation: boolean
  userMarkdown: string
  idempotencyKey: string
  selectedModel?: string
  /** True sends mode "edit": the agent rewrites the subject note instead of
   * answering in the conversation. */
  noteEdit?: boolean
  attachments: readonly AgentChatAttachmentInput[]
}

export interface AgentChatComposerRequest {
  subjectNoteId?: string
  subjectNotebookId?: string
  conversationNotebookId?: string
  userMarkdown: string
  idempotencyKey: string
  model?: string
  mode?: 'edit'
  attachments?: AgentChatAttachmentInput[]
}

/** Builds the exact agent request used by the composer. Keeping this DOM-free
 * makes the New chat contract independently regression-testable. */
export function buildAgentChatComposerRequest(options: AgentChatComposerRequestOptions): AgentChatComposerRequest {
  const conversationId = options.newConversation
    ? undefined
    : options.activeConversationId ?? latestConversationId(options.conversations)
  return {
    ...(options.subject.kind === 'note'
      ? { subjectNoteId: options.subject.id }
      : { subjectNotebookId: options.subject.id }),
    ...(conversationId ? { conversationNotebookId: conversationId } : {}),
    userMarkdown: options.userMarkdown.trim(),
    idempotencyKey: options.idempotencyKey,
    ...(options.selectedModel ? { model: options.selectedModel } : {}),
    ...(options.noteEdit ? { mode: 'edit' as const } : {}),
    ...(options.attachments.length > 0 ? { attachments: [...options.attachments] } : {}),
  }
}

export function composerSubmitKind(memoOnly: boolean): 'memo' | 'agent' {
  return memoOnly ? 'memo' : 'agent'
}

export function normalizeSelectedAgentModel(
  selected: string | undefined,
  models: readonly AgentModel[],
  configuredModel: string | null | undefined,
): string | undefined {
  if (selected && models.some((model) => model.modelId === selected)) return selected
  return configuredModel ?? models[0]?.modelId
}

export function memoOnlyControlAttributes(selected: boolean): {
  ariaPressed: boolean
  ariaLabel: string
  title: string
} {
  return { ariaPressed: selected, ariaLabel: 'Memo only', title: 'Memo only' }
}

export function removeComposerAttachment<T>(attachments: readonly T[], index: number): T[] {
  return attachments.filter((_, attachmentIndex) => attachmentIndex !== index)
}

function hasUnsafeFilenameCharacters(filename: string): boolean {
  return /[\\/]/.test(filename) || Array.from(filename).some((character) => {
    const codePoint = character.codePointAt(0) ?? 0
    return codePoint <= 0x1F || codePoint === 0x7F
  })
}

/** Browser file inputs commonly report generic MIME values. Match the server's
 * safe-extension fallback so client feedback does not reject a valid request. */
export function composerAttachmentMediaType(file: Pick<File, 'name' | 'type'>): string | undefined {
  const declared = file.type.split(';', 1)[0]?.toLowerCase()
  if (declared && !['application/octet-stream', 'binary/octet-stream'].includes(declared)) {
    return declared
  }
  return extensions[file.name.split('.').pop()?.toLowerCase() ?? ''] ?? declared
}

export async function validateComposerFiles(files: readonly File[]): Promise<{ accepted: boolean; message: string }> {
  if (files.length > 4) return { accepted: false, message: 'Attach at most four UTF-8 text files totaling 1 MiB.' }
  if (files.reduce((total, file) => total + file.size, 0) > 1_048_576) return { accepted: false, message: 'Attach at most four UTF-8 text files totaling 1 MiB.' }
  const identities = new Set<string>()
  for (const file of files) {
    const mediaType = composerAttachmentMediaType(file)
    if (!file.name || new TextEncoder().encode(file.name).byteLength > 255 || hasUnsafeFilenameCharacters(file.name) || file.size === 0 || !mediaType || !allowedTypes.has(mediaType)) {
      return { accepted: false, message: 'Attachments must be non-empty supported text files with safe filenames.' }
    }
    try {
      new TextDecoder('utf-8', { fatal: true }).decode(await file.arrayBuffer())
    } catch {
      return { accepted: false, message: 'Attachments must contain valid UTF-8 text.' }
    }
    const identity = `${file.name}\u0000${file.size}\u0000${file.lastModified}`
    if (identities.has(identity)) return { accepted: false, message: 'Duplicate attachments are not allowed.' }
    identities.add(identity)
  }
  return { accepted: true, message: '' }
}
