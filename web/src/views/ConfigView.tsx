import { For, type JSX } from 'solid-js'
import { useApp } from '../state/appStore'
import { clampFontScale, fontScaleBounds } from '../notes/settings'

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
    <div class="config-view">
      <header class="search-head">
        <span class="eyebrow">Configuration</span>
        <h1>Settings</h1>
      </header>

      <section class="config-section">
        <h2>Font size</h2>
        <p class="pane-note">
          Applies to the whole app. Stored in this kaiba store's sqlite, so every
          client of the store shares it.
        </p>
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
        <h2>Layout</h2>
        <p class="pane-note">
          Pane widths are resizable by dragging the borders beside the left and
          right panes (kept per browser).
        </p>
        <button type="button" class="secondary" onClick={app.resetPaneWidths}>
          Reset pane widths
        </button>
      </section>
    </div>
  )
}
