import { Show, type JSX } from 'solid-js'
import { TabPanel, Tabs, type TabDescriptor } from '../components/Tabs'
import { FileTreeTab } from '../components/FileTreeTab'
import { TocTab } from '../components/TocTab'
import { useApp } from '../state/appStore'
import type { LeftTab } from '../state/paneState'

const tabs: readonly TabDescriptor<LeftTab>[] = [
  { value: 'files', label: 'Files' },
  { value: 'contents', label: 'Contents' },
]

export function LeftPane(): JSX.Element {
  const app = useApp()
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
            tabs={tabs}
            active={app.state.pane.leftTab}
            idPrefix="left"
            onSelect={app.setLeftTab}
          />
          <button
            type="button"
            class="pane-fold"
            aria-label="Collapse the library pane"
            aria-expanded={true}
            onClick={app.toggleLeftPane}
          >‹</button>
        </div>
        <div class="pane-body">
          <TabPanel idPrefix="left" value="files" active={app.state.pane.leftTab}>
            <FileTreeTab />
          </TabPanel>
          <TabPanel idPrefix="left" value="contents" active={app.state.pane.leftTab}>
            <TocTab />
          </TabPanel>
        </div>
      </Show>
    </aside>
  )
}
