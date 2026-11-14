import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NotebookId } from '../notes/ids'
import { WorkspaceIcon } from './WorkspaceIcon'
import { MemoComposerControls } from './ChatComposer'
import { fileToChatAttachment, normalizeSelectedAgentModel, validateComposerFiles } from '../notes/memoComposer'
import type { AgentModel } from '../notes/types'
import '../agent-footer.css'
import { MemoTab } from './MemoTab'

export function AgentFooter(props: {
  onConversation: (id: NotebookId) => void
  conversationRequest?: { notebookId?: NotebookId }
}): JSX.Element {
  const app = useApp()
  const [expanded, setExpanded] = createSignal(false)
  const [showHistory, setShowHistory] = createSignal(false)
  const [selectedConversation, setSelectedConversation] = createSignal<NotebookId>()
  const [largePanel, setLargePanel] = createSignal(false)
  createEffect(() => {
    const request = props.conversationRequest
    if (!request) return
    setSelectedConversation(request.notebookId)
    setShowHistory(false)
    setExpanded(true)
  })
  const contextLabel = () => `${app.notebook()?.title ?? 'Current notebook'}${app.state.noteId ? ` · Page ${app.state.note?.noteNumber ?? '…'}` : ''}`
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
    void app.client.agentModels(app.state.settings.agentProvider).then((catalog) => {
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
  return <footer class="agent-footer" data-large={largePanel()}>
    <Show when={expanded()}>
      <div class="footer-chat-tools" role="group" aria-label="AI conversation controls">
        <Show when={showHistory() || selectedConversation()}>
          <button type="button" class="workspace-icon" aria-label="Return to current page discussion" title={`Return to ${contextLabel()}`} onClick={() => { setSelectedConversation(undefined); setShowHistory(false) }}><WorkspaceIcon name="back" /></button>
        </Show>
        <button type="button" class="workspace-icon" aria-label="AI conversations" title="Saved AI conversations" aria-pressed={showHistory()} onClick={() => setShowHistory(!showHistory())}><WorkspaceIcon name="timeline" /></button>
        <button type="button" class="workspace-icon" aria-label={largePanel() ? 'Reduce conversation panel' : 'Enlarge conversation panel'} title={largePanel() ? 'Reduce conversation panel' : 'Enlarge conversation panel'} aria-pressed={largePanel()} onClick={() => setLargePanel(!largePanel())}><WorkspaceIcon name="expand" /></button>
      </div>
      <Show when={!showHistory()} fallback={
        <section class="footer-conversation-history" aria-label="Saved AI conversations">
          <p class="footer-context-label">AI conversations</p>
          <For each={app.state.notebooks.filter((notebook) => notebook.type === 'AGENT_CHAT')} fallback={<p class="pane-empty">No conversations yet.</p>}>
            {(notebook) => <button type="button" class="footer-history-entry" onClick={() => { setSelectedConversation(notebook.notebookId); setShowHistory(false) }}>{notebook.title}</button>}
          </For>
        </section>
      }>
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
            onModelChange={(model) => app.updateSettings({ agentModel: model || undefined })}
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
          <MemoTab conversationNotebookId={selectedConversation() ?? (app.notebook()?.type === 'AGENT_CHAT' ? app.state.notebookId : undefined)} />
        </section>
      </Show>
      </Show>
    </Show>
    <button type="button" class="workspace-icon agent-footer-launcher" aria-label={expanded() ? 'Close AI composer' : 'Ask AI'}
      title={expanded() ? 'Close AI composer' : 'Discuss the current notebook or page (⌘/Ctrl J). Saved conversations are available in AI conversations.'}
      aria-expanded={expanded()} onClick={() => {
        setExpanded(!expanded())
      }}><WorkspaceIcon name={expanded() ? 'close' : 'ai'} /></button>
  </footer>
}
