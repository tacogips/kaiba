import { Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { errorMessage, useApp } from '../state/appStore'
import type { NotebookId } from '../notes/ids'
import { WorkspaceIcon } from './WorkspaceIcon'
import { MemoComposerControls } from './ChatComposer'
import { fileToChatAttachment, normalizeSelectedAgentModel, validateComposerFiles } from '../notes/memoComposer'
import type { AgentModel } from '../notes/types'

export function AgentFooter(props: { onConversation: (id: NotebookId) => void }): JSX.Element {
  const app = useApp()
  const [expanded, setExpanded] = createSignal(false)
  const draft = app.writingDrafts.get('footer-agent')
  const [providers, setProviders] = createSignal<string[]>([])
  const [configuredProvider, setConfiguredProvider] = createSignal<string>()
  const [models, setModels] = createSignal<AgentModel[]>([])
  const [catalogError, setCatalogError] = createSignal('')
  let generation = 0
  onCleanup(() => { generation += 1 })
  createEffect(() => {
    if (!expanded()) return
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
  return <footer class="agent-footer">
    <Show when={expanded()}>
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
    </Show>
    <button type="button" class="workspace-icon" aria-label="Ask AI" title="Ask AI (⌘/Ctrl J)"
      aria-expanded={expanded()} onClick={() => {
        setExpanded(!expanded())
      }}><WorkspaceIcon name={expanded() ? 'close' : 'ai'} /></button>
  </footer>
}
