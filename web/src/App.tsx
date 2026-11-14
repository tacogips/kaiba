import { ChatbookView } from './views/ChatbookView'
import { CaptureView, isCapturePathname } from './views/CaptureView'
import { AppStoreProvider } from './state/appStore'
import './chatbook.css'
import './notes-detail.css'
import './learning.css'
import './workspace.css'
import './light-theme.css'

/// Kaiba serves exactly one surface: the chatbook note reader against
/// `kaiba serve` (riela's "cli-serve" host mode). No profile switching, no
/// workflow views.
///
/// The one exception is anywhere capture (design C5): the server serves this
/// same bundle at the real path `/note/capture`, so the boot decision is the
/// pathname. Routing itself stays hash-based, and both surfaces share one
/// store so the capture page reuses the registered client's credential.
export function App() {
  if (isCapturePathname(window.location.pathname)) {
    return (
      <AppStoreProvider>
        <CaptureView />
      </AppStoreProvider>
    )
  }
  return (
    <AppStoreProvider>
      <ChatbookView />
    </AppStoreProvider>
  )
}
