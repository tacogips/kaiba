import { For, Show, createEffect, createSignal, on, onCleanup, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NotebookId } from '../notes/ids'
import { WorkspaceIcon } from './WorkspaceIcon'
import { MemoComposerControls } from './ChatComposer'
import { fileToChatAttachment, normalizeSelectedAgentModel, validateComposerFiles } from '../notes/memoComposer'
import type { AgentModel } from '../notes/types'
import '../agent-footer.css'
import { MemoTab } from './MemoTab'
import { aiNoteContext, type AIContextSelection } from '../notes/aiNoteContext'

export function AgentFooter(props: {
  onConversation: (id: NotebookId) => void
  conversationRequest?: { notebookId?: NotebookId }
}): JSX.Element {
  const app = useApp()
  const [expanded, setExpanded] = createSignal(false)
  const focusPanel = () => {
    setExpanded(true)
    queueMicrotask(() => document.querySelector<HTMLTextAreaElement>('.agent-footer textarea')?.focus())
  }
  window.addEventListener('kaiba-focus-ai', focusPanel)
  onCleanup(() => window.removeEventListener('kaiba-focus-ai', focusPanel))
  const [showHistory, setShowHistory] = createSignal(false)
  const [selectedConversation, setSelectedConversation] = createSignal<NotebookId>()
  const [largePanel, setLargePanel] = createSignal(false)
  const [contextMode, setContextMode] = createSignal<AIContextSelection['mode']>('current')
  createEffect(on(() => app.state.notebookId, () => setContextMode(app.state.noteId ? 'current' : 'notebook')))
  const [contextStart, setContextStart] = createSignal('1')
  const [contextEnd, setContextEnd] = createSignal('1')
  const contextAttachments = async () => {
    const notebook = app.notebook()
    if (!notebook || notebook.type === 'AGENT_CHAT') return []
    const current = app.state.note
    const selection = { mode: contextMode(), start: contextStart(), end: contextEnd() }
    return aiNoteContext(app.client, notebook, current, selection, app.notebookWritingContext?.())
  }
  const [panelHeight, setPanelHeight] = createSignal<number>()
  let footer!: HTMLElement
  const resizePanel = (event: PointerEvent & { currentTarget: HTMLElement }) => {
    if (event.button !== 0 || largePanel()) return
    event.preventDefault()
    const handle = event.currentTarget
    const startY = event.clientY
    const startHeight = footer.getBoundingClientRect().height
    handle.setPointerCapture(event.pointerId)
    const move = (next: PointerEvent) => setPanelHeight(Math.round(Math.max(160, Math.min(window.innerHeight - 80, startHeight + startY - next.clientY))))
    const finish = () => {
      handle.removeEventListener('pointermove', move)
      handle.removeEventListener('pointerup', finish)
      handle.removeEventListener('pointercancel', finish)
      handle.removeEventListener('lostpointercapture', finish)
    }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', finish)
    handle.addEventListener('pointercancel', finish)
    handle.addEventListener('lostpointercapture', finish)
  }
  const escapeFullscreen = (event: KeyboardEvent) => {
    if (event.key === 'Escape' && !event.defaultPrevented && !document.querySelector('dialog[open], [role="dialog"]')) setLargePanel(false)
  }
  window.addEventListener('keydown', escapeFullscreen)
  onCleanup(() => window.removeEventListener('keydown', escapeFullscreen))
  createEffect(() => {
    const request = props.conversationRequest
    if (!request) return
    setSelectedConversation(request.notebookId)
    setShowHistory(false)
    setExpanded(true)
  })
  const contextLabel = () => `${app.notebook()?.title ?? 'Current notebook'}${app.notebookWritingContext?.() ? ` · Note ${app.notebookWritingContext()!.noteNumber}` : app.state.noteId ? ` · Page ${app.state.note?.noteNumber ?? '…'}` : ''}`
  const conversationTitle = () => app.state.notebooks.find((notebook) => notebook.notebookId === selectedConversation())?.title ?? 'Saved conversation'
  const draft = app.writingDrafts.get('footer-agent')
  const [providers, setProviders] = createSignal<string[]>([])
  const [configuredProvider, setConfiguredProvider] = createSignal<string>()
  const [models, setModels] = createSignal<AgentModel[]>([])
  const [catalogError, setCatalogError] = createSignal('')
  let generation = 0
  onCleanup(() => { generation += 1 })
  createEffect(() => {
    if (!expanded() || showHistory() || selectedConversation() || app.state.noteId || app.state.notebookId) return
    void app.state.catalogRevision
    const request = ++generation
    void (app.client.allAgentModels ? app.client.allAgentModels(app.state.settings.agentProvider) : app.client.agentModels(app.state.settings.agentProvider)).then((catalog) => {
      if (request !== generation) return
      setProviders(catalog.providers ?? [])
      setConfiguredProvider(catalog.configuredProvider ?? undefined)
      if (app.state.settings.agentProvider && catalog.providers && !catalog.providers.includes(app.state.settings.agentProvider)) {
        app.updateSettings({ agentProvider: catalog.configuredProvider ?? undefined, agentModel: undefined })
      }
      setModels(catalog.models)
      setCatalogError('')
      const model = normalizeSelectedAgentModel(app.state.settings.agentModel, catalog.models, catalog.configuredModel)
      if (model && model !== app.state.settings.agentModel) app.updateSettings({ agentModel: model })
    }).catch(() => {
      if (request === generation) setCatalogError('Could not load models. Check the connection in Settings.')
    })
  })
  const stageFiles = async (files: FileList | readonly File[] | null) => {
    if (!files || draft.busy() || draft.submission()) return
    draft.setBusy(true)
    try {
      const next = [...draft.files(), ...Array.from(files)]
      const validation = await validateComposerFiles(next)
      if (!validation.accepted) { draft.setError(validation.message); return }
      draft.setFiles(next)
      draft.setError('')
    } catch (error) { draft.setError(errorMessage(error)) }
    finally { draft.setBusy(false) }
  }
  const send = async (event: Event) => {
    event.preventDefault()
    if (draft.busy() || !draft.text().trim()) return
    draft.setBusy(true)
    draft.setError('')
    try {
      const submission = draft.submission() ?? {
        key: crypto.randomUUID(), body: draft.text(), model: app.state.settings.agentModel,
        provider: app.state.settings.agentProvider ?? configuredProvider(),
        attachments: await Promise.all(draft.files().map(fileToChatAttachment)),
      }
      draft.setSubmission(submission)
      const result = await app.client.sendAgentChatMessage({
        userMarkdown: submission.body, idempotencyKey: submission.key,
        ...(submission.provider ? { provider: submission.provider } : {}),
        ...(submission.model ? { model: submission.model } : {}),
        ...(submission.attachments?.length ? { attachments: submission.attachments } : {}),
      })
      if (!result.conversationNotebookId) throw new Error('The server did not return a conversation.')
      draft.setText('')
      draft.setFiles([])
      draft.setSubmission(undefined)
      setExpanded(false)
      props.onConversation(result.conversationNotebookId)
      await app.refreshCatalog()
    } catch (error) {
      draft.setError(errorMessage(error))
    } finally { draft.setBusy(false) }
  }
  return <footer ref={footer} class="agent-footer" data-large={expanded() && largePanel()} data-sized={expanded() && panelHeight() !== undefined}
    style={{ height: expanded() && !largePanel() && panelHeight() !== undefined ? `${panelHeight()}px` : undefined }}>
    <Show when={expanded()}>
      <div class="footer-pane-splitter" role="separator" aria-orientation="horizontal" aria-label="Resize the bottom pane"
        title="Drag to resize the bottom pane; double-click to reset" onPointerDown={resizePanel} onDblClick={() => setPanelHeight(undefined)} />
      <div class="footer-chat-tools" role="group" aria-label="AI conversation controls">
        <Show when={showHistory() || selectedConversation()}>
          <button type="button" class="workspace-icon" aria-label="Return to current page discussion" title={`Return to ${contextLabel()}`} onClick={() => { setSelectedConversation(undefined); setShowHistory(false) }}><WorkspaceIcon name="back" /></button>
        </Show>
        <button type="button" class="workspace-icon" aria-label="AI conversations" title="Saved AI conversations" aria-pressed={showHistory()} onClick={() => setShowHistory(!showHistory())}><WorkspaceIcon name="timeline" /></button>
        <button type="button" class="workspace-icon" aria-label={largePanel() ? 'Exit full screen' : 'Full screen'} title={largePanel() ? 'Exit full screen (Escape)' : 'Show AI conversation in full screen'} aria-pressed={largePanel()} onClick={() => setLargePanel(!largePanel())}><WorkspaceIcon name={largePanel() ? 'collapse' : 'expand'} /></button>
        <button type="button" class="workspace-icon" aria-label="Close AI composer" title="Collapse the AI panel" aria-expanded="true"
          onClick={() => { setExpanded(false); setLargePanel(false) }}><WorkspaceIcon name="close" /></button>
      </div>
      <Show when={!showHistory()} fallback={
        <section class="footer-conversation-history" aria-label="Saved AI conversations">
          <p class="footer-context-label">AI conversations</p>
          <For each={app.state.notebooks.filter((notebook) => notebook.type === 'AGENT_CHAT')} fallback={<p class="pane-empty">No conversations yet.</p>}>
            {(notebook) => <button type="button" class="footer-history-entry" onClick={() => { setSelectedConversation(notebook.notebookId); setShowHistory(false) }}>{notebook.title}</button>}
          </For>
        </section>
      }>
      <Show when={app.notebook() && app.notebook()?.type !== 'AGENT_CHAT'}>
        <div class="footer-context-picker" role="group" aria-label="AI reference context">
          <label>Context <select aria-label="AI context scope" value={contextMode()} onChange={(event) => setContextMode(event.currentTarget.value as AIContextSelection['mode'])}>
            <option value="notebook">Notebook</option><option value="current" disabled={!app.state.noteId && !app.notebookWritingContext?.()}>Current note</option><option value="note">Note number</option><option value="range">Note range</option>
          </select></label>
          <Show when={contextMode() === 'note' || contextMode() === 'range'}><label>Note <input aria-label="Context start note" type="number" min="1" value={contextStart()} onInput={(event) => setContextStart(event.currentTarget.value)} /></label></Show>
          <Show when={contextMode() === 'range'}><label>to <input aria-label="Context end note" type="number" min={contextStart()} value={contextEnd()} onInput={(event) => setContextEnd(event.currentTarget.value)} /></label></Show>
        </div>
      </Show>
      <Show when={selectedConversation() || app.state.noteId || app.state.notebookId} fallback={
        <form class="footer-agent-composer" onSubmit={(event) => void send(event)}>
          <MemoComposerControls memoOnly={false} noteEdit={false} canNoteEdit={false} hideModes autofocus
            busy={draft.busy()} readOnly={Boolean(draft.submission())}
            draft={draft.text()} attachments={draft.files()} models={models()} selectedModel={app.state.settings.agentModel}
            providers={providers()} selectedProvider={app.state.settings.agentProvider ?? configuredProvider()}
            onProviderChange={(agentProvider) => app.updateSettings({ agentProvider, agentModel: undefined })}
            extensionsEnabled={!draft.busy() && !draft.submission()} inputLabel="Ask AI anything" sendLabel="Send to AI"
            onStageFiles={stageFiles} onDraftChange={(value) => { if (!draft.submission()) draft.setText(value) }}
            onRemoveAttachment={(index) => { if (!draft.submission()) draft.setFiles(draft.files().filter((_, i) => i !== index)) }}
            onModelChange={(model, provider) => app.updateSettings({ agentModel: model || undefined, ...(provider ? { agentProvider: provider } : {}) })}
            onToggleMemoOnly={() => {}} onToggleNoteEdit={() => {}}
            onSubmit={() => void send(new Event('submit', { cancelable: true }))} />
          <Show when={catalogError()}><p role="alert" class="note-inline-error">{catalogError()}</p></Show>
          <Show when={draft.error()}><p role="alert" class="note-inline-error">{draft.error()}</p></Show>
        </form>
      }>
        <section class="footer-contextual-chat" aria-label={selectedConversation() ? 'Saved conversation' : 'Discussion for the current selection'}>
          <p class="footer-context-label" title={selectedConversation() ? conversationTitle() : contextLabel()}>
            {selectedConversation() ? `Saved conversation: ${conversationTitle()}` : contextLabel()}
          </p>
          <MemoTab contextAttachments={contextAttachments} conversationNotebookId={selectedConversation() ?? (app.notebook()?.type === 'AGENT_CHAT' ? app.state.notebookId : undefined)} />
        </section>
      </Show>
      </Show>
    </Show>
    <Show when={!expanded()}><button type="button" class="workspace-icon agent-footer-launcher" aria-label="Ask AI"
      title="Discuss the current notebook or page (⌘/Ctrl J). Saved conversations are available in AI conversations."
      aria-expanded="false" onClick={() => setExpanded(true)}><WorkspaceIcon name="ai" /></button></Show>
  </footer>
}
