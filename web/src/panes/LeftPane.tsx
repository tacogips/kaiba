import { Show, createMemo, type JSX } from 'solid-js'
import { TabPanel, Tabs, type TabDescriptor } from '../components/Tabs'
import { FileTreeTab } from '../components/FileTreeTab'
import { TocTab } from '../components/TocTab'
import { useApp } from '../state/appStore'
import type { LeftTab } from '../state/paneState'

export function LeftPane(props: { onClose?: () => void; onNavigate?: () => void } = {}): JSX.Element {
  const app = useApp()
  const hasContents = () => Boolean(app.state.notebookId || app.state.note)
  const tabs = createMemo<readonly TabDescriptor<LeftTab>[]>(() => [
    { value: 'files', label: 'Files' },
    { value: 'contents', label: 'Contents', disabled: !hasContents() },
  ])
  const activeTab = (): LeftTab => hasContents() ? app.state.pane.leftTab : 'files'
  return (
    <aside class="pane pane-left" aria-label="Library and contents">
      <Show
        when={app.state.pane.leftOpen}
        fallback={
          <div class="pane-rail">
            <button
              type="button"
              class="rail-button"
              aria-label="Open the library pane"
              aria-expanded={false}
              onClick={app.toggleLeftPane}
            >›</button>
            <span class="rail-label">Files</span>
          </div>
        }
      >
        <div class="pane-head">
          <Tabs
            label="Library and contents"
            tabs={tabs()}
            active={activeTab()}
            idPrefix="left"
            onSelect={app.setLeftTab}
          />
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the library pane"
            aria-expanded={true}
            onClick={() => {
              app.toggleLeftPane()
              props.onClose?.()
            }}
          >‹</button>
        </div>
        <div class="pane-body">
          <TabPanel idPrefix="left" value="files" active={activeTab()}>
            <FileTreeTab onNavigate={props.onNavigate} />
          </TabPanel>
          <TabPanel idPrefix="left" value="contents" active={activeTab()}>
            <TocTab onNavigate={props.onNavigate} />
          </TabPanel>
        </div>
      </Show>
    </aside>
  )
}
