import { ChatbookView } from './views/ChatbookView'
import { AppStoreProvider } from './state/appStore'
import './chatbook.css'
import './notes-detail.css'

/// Kaiba serves exactly one surface: the chatbook note reader against
/// `kaiba serve` (riela's "cli-serve" host mode). No profile switching, no
/// workflow views.
export function App() {
  return (
    <AppStoreProvider>
      <ChatbookView />
    </AppStoreProvider>
  )
}
