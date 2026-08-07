import { NotesView } from './views/NotesView'

/// Kaiba serves exactly one surface: the note viewer against `kaiba serve`
/// (riela's "cli-serve" host mode). No profile switching, no workflow views.
export function App() {
  return (
    <div class="app-shell">
      <a class="skip-link" href="#main-content">Skip to content</a>
      <aside class="sidebar">
        <div class="brand">
          <div class="brand-mark">K</div>
          <div><strong>Kaiba</strong><span>Note viewer</span></div>
        </div>
        <div class="server-card" role="status" aria-live="polite">
          <span classList={{ dot: true, live: true }} />
          <div><strong>kaiba serve</strong><span>Local note API</span></div>
        </div>
      </aside>
      <main id="main-content" tabindex="-1">
        <header class="topbar">
          <div><span class="eyebrow">HOST</span><strong>kaiba serve</strong></div>
          <span class="api-pill">NOTE API</span>
        </header>
        <NotesView mode="cli-serve" profileName="" />
      </main>
    </div>
  )
}
