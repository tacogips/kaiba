import Foundation

// Entry point for the Kaiba macOS menu-bar app (the Cask-released `.app`). It is
// an accessory (LSUIElement) app: no Dock icon, no window — just a status-bar
// item that runs the note server resident and lets the person start/stop it,
// open the web UI, and toggle launch-at-login
// (`design-docs/specs/macos-menu-bar-app.md`).

#if canImport(AppKit)
import AppKit

let application = NSApplication.shared
let delegate = KaibaMenuBarAppDelegate()
application.delegate = delegate
// Accessory: resident in the menu bar with no Dock tile or main window.
application.setActivationPolicy(.accessory)
application.run()
#else
FileHandle.standardError.write(Data("kaiba menu-bar app runs on macOS only\n".utf8))
exit(1)
#endif
