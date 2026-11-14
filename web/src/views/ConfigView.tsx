import { For, Show, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { clampFontScale, fontScaleBounds, type PDFTextMode } from '../notes/settings'
import { ServerConnectionSettings } from '../components/ServerConnectionSettings'
import { UserAgentSettings } from '../components/UserAgentSettings'
import { SearchEngineSettings } from '../components/SearchEngineSettings'
import { VimSettings } from '../components/VimSettings'
import '../components/form-controls.css'
import { WorkspaceIcon } from '../components/WorkspaceIcon'

// The config screen. Settings live in the kaiba store's sqlite
// (`app_settings`), so they follow the store across browsers and devices;
// changes apply immediately and persist debounced.

const fontPresets: ReadonlyArray<{ label: string; scale: number }> = [
  { label: 'Small', scale: 1 },
  { label: 'Default', scale: 1.15 },
  { label: 'Large', scale: 1.3 },
  { label: 'Extra large', scale: 1.5 },
]

export function ConfigView(): JSX.Element {
  const app = useApp()
  const scale = () => app.state.settings.fontScale

  return (
    <main class="config-view" id="main-content" tabindex="-1">
      <header class="search-head">
        <h1>Settings</h1>
        <button type="button" class="secondary form-icon-button" aria-label="Back to reader" title="Back to reader" onClick={app.openReader}><WorkspaceIcon name="back" /></button>
      </header>
      <Show when={app.settingsSave?.status() !== 'idle' && app.settingsSave}>
        {(save) => <div class="config-preference-save" aria-label="Preference save status">
          <Show when={save().status() === 'saving'}><p role="status">Saving preferences…</p></Show>
          <Show when={save().status() === 'saved'}><p role="status">Preferences saved.</p></Show>
          <Show when={save().status() === 'error'}><p role="alert" class="note-inline-error">
            Preferences could not be saved: {save().error()}
            <button type="button" class="secondary form-icon-button" aria-label="Retry saving preferences" title="Retry saving preferences" onClick={save().retry}><WorkspaceIcon name="refresh" /></button>
          </p></Show>
        </div>}
      </Show>

      <section class="config-section">
        <h2>Font size</h2>
        <div class="config-presets" role="group" aria-label="Font size presets">
          <For each={fontPresets}>{(preset) =>
            <button
              type="button"
              classList={{ secondary: scale() !== preset.scale }}
              aria-pressed={scale() === preset.scale}
              onClick={() => app.updateSettings({ fontScale: preset.scale })}
            >{preset.label}</button>}
          </For>
        </div>
        <label class="config-slider">
          <span>Fine tune ({Math.round(scale() * 100)}%)</span>
          <input
            type="range"
            min={fontScaleBounds.minimum}
            max={fontScaleBounds.maximum}
            step="0.05"
            value={scale()}
            onInput={(event) => {
              const value = Number.parseFloat(event.currentTarget.value)
              if (Number.isFinite(value)) app.updateSettings({ fontScale: clampFontScale(value) })
            }}
          />
        </label>
        <p class="config-preview" aria-hidden="true">
          The quick brown fox jumps over the lazy dog. — 素早い茶色の狐が怠け者の犬を飛び越える。
        </p>
      </section>

      <section class="config-section">
        <h2>PDF import</h2>
        <label>Default text extraction
          <select value={app.state.settings.pdfTextMode ?? ''}
            onChange={(event) => app.updateSettings({ pdfTextMode: event.currentTarget.value ? event.currentTarget.value as PDFTextMode : undefined })}>
            <option value="">Use server default</option>
            <option value="prefer-pdf-text">Use PDF text, fall back to OCR</option>
            <option value="ocr-only">OCR only</option>
          </select>
        </label>
        <p>You can override this choice for each import.</p>
      </section>

      <VimSettings />
      <ServerConnectionSettings />

      <UserAgentSettings />

      <SearchEngineSettings />

      <section class="config-section">
        <h2>Layout</h2>
        <button type="button" class="secondary form-icon-button" aria-label="Reset pane widths" title="Reset pane widths" onClick={app.resetPaneWidths}>
          <WorkspaceIcon name="refresh" />
        </button>
      </section>
    </main>
  )
}
