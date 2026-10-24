import { For, Show, createMemo, type JSX } from 'solid-js'
import type { NotebookId, TagId } from '../notes/ids'
import { TabPanel, Tabs, type TabDescriptor } from '../components/Tabs'
import { SourceAnalyses } from '../components/SourceAnalyses'
import { DocumentPageOCRControl } from '../components/DocumentPageOCRControl'
import { NoteTagsTab } from '../components/NoteTagsTab'
import { NoteInfoTab } from '../components/NoteInfoTab'
import { LinkedDocsTab } from '../components/LinkedDocsTab'
import { ConnectionRecommendationsTab } from '../components/ConnectionRecommendationsTab'
import { NotebookTagsTab } from '../components/NotebookAggregateTabs'
import { TagPane } from '../components/TagPane'
import { useApp } from '../state/appStore'
import type { RightTab } from '../state/paneState'

// The right pane follows the selection: with a note selected it shows that
// note's tags, analysis and incoming backlinks; with only a notebook open it
// shows notebook tags and asks for a note selection before listing backlinks. Discussions live in the bottom AI composer;
// The AI tab lists saved conversations. A tag selection
// (`?tag=` on the route) replaces all of it with the cross-notebook tag pane.

export function RightPane(props: { onClose?: () => void; onConversation?: (id: NotebookId) => void } = {}): JSX.Element {
  const app = useApp()
  const noteMode = createMemo(() => Boolean(app.state.noteId))
  const tagId = createMemo(() => app.tagPaneTagId())
  const activeTab = () => app.state.pane.rightTab === 'memo' ? 'history' : app.state.pane.rightTab
  const tabs: readonly TabDescriptor<RightTab>[] = [
    { value: 'history', label: 'AI', title: 'Saved AI conversations' },
    { value: 'tags', label: 'Tags' },
    { value: 'analysis', label: 'Analysis' },
    { value: 'similar', label: 'Similar' },
    { value: 'same-topic', label: 'Same topic' },
    { value: 'related-topics', label: 'Related topics' },
    { value: 'links', label: 'Backlinks', title: 'Notes that link to the selected note or page' },
  ]
  return (
    <aside class="pane pane-right" aria-label={tagId() ? 'Tag details' : noteMode() ? 'Note details' : 'Notebook details'}>
      <Show
        when={app.state.pane.rightOpen}
        fallback={
          <div class="pane-rail">
            <button
              type="button"
              class="rail-button"
              aria-label="Open the details pane" title="Open the details pane"
              aria-expanded={false}
              onClick={app.toggleRightPane}
            >‹</button>
            <span class="rail-label">AI / Tags / Analysis</span>
          </div>
        }
      >
        <div class="pane-head">
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the details pane" title="Collapse the details pane"
            aria-expanded={true}
            onClick={() => {
              app.toggleRightPane()
              props.onClose?.()
            }}
          >›</button>
          <Tabs
            label={noteMode() ? 'Note details' : 'Notebook details'}
            tabs={tabs}
            active={activeTab()}
            idPrefix="right"
            onSelect={(tab) => { app.closeTagPane(); app.setRightTab(tab) }}
          />
        </div>
        <Show when={!tagId()} fallback={<TagPane tagId={tagId() as TagId} />}>
        <div class="pane-body">
          <TabPanel idPrefix="right" value="history" active={activeTab()}>
            <div class="agent-history" aria-label="Saved AI conversations">
              <For each={app.state.notebooks.filter((notebook) => notebook.type === 'AGENT_CHAT')}
                fallback={<p class="pane-empty">No conversations yet.</p>}>
                {(notebook) => <button type="button" class="tree-label" onClick={() => props.onConversation?.(notebook.notebookId)}>
                  <span class="tree-label-text">{notebook.title}</span>
                </button>}
              </For>
            </div>
          </TabPanel>
          <TabPanel idPrefix="right" value="tags" active={activeTab()}>
            <Show when={noteMode()} fallback={<NotebookTagsTab />}><NoteTagsTab /></Show>
          </TabPanel>
          <TabPanel idPrefix="right" value="analysis" active={activeTab()}>
            <DocumentPageOCRControl />
            <NoteInfoTab />
            <Show keyed when={app.state.notebookId}>{(id) => <SourceAnalyses app={app} notebookId={id} />}</Show>
          </TabPanel>
          <TabPanel idPrefix="right" value="links" active={activeTab()}>
            <LinkedDocsTab />
          </TabPanel>
          <TabPanel idPrefix="right" value="similar" active={activeTab()}><ConnectionRecommendationsTab category="similar" /></TabPanel>
          <TabPanel idPrefix="right" value="same-topic" active={activeTab()}><ConnectionRecommendationsTab category="same-topic" /></TabPanel>
          <TabPanel idPrefix="right" value="related-topics" active={activeTab()}><ConnectionRecommendationsTab category="related-topics" /></TabPanel>
        </div>
        </Show>
      </Show>
    </aside>
  )
}
