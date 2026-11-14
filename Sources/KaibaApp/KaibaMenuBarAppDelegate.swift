#if canImport(AppKit)
import AppCore
import AppKit
import AppServer
import Foundation
import ServiceManagement

/// Drives the status-bar item and the resident note server. All UI touches the
/// status item on the main actor; the server itself is an actor started off the
/// main thread and its result is folded back onto the menu
/// (`design-docs/specs/macos-menu-bar-app.md`).
@MainActor
final class KaibaMenuBarAppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var runtime: KaibaServerRuntime?
  private var startInfo: KaibaServerStartInfo?
  private var lastError: String?
  private var isBusy = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = Self.brainStatusImage()
      button.imageScaling = .scaleProportionallyDown
      button.toolTip = "Kaiba note server"
    }
    self.statusItem = item
    rebuildMenu()
    // Auto-start the server on launch (the resident default the person chose).
    startServer()
  }

  // MARK: - Status icon

  /// The stylized brain menu-bar icon, matching the web app favicon
  /// (`web/public/favicon.svg`). A monochrome, stroke-only glyph rendered as a
  /// template image so macOS tints it to the menu-bar appearance. Falls back to
  /// the `brain` SF Symbol — itself a stylized brain — if SVG decoding fails.
  private static func brainStatusImage() -> NSImage {
    let svg = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
        <g fill="none" stroke="#000000" stroke-width="4" stroke-linecap="round" stroke-linejoin="round">
          <path d="M32 13 C 26 8, 17 9, 16 16 C 9 16, 6 24, 11 30 C 6 35, 9 43, 16 44 \
      C 16 51, 24 55, 30 50 C 30 53, 34 53, 34 50 C 40 55, 48 51, 48 44 \
      C 55 43, 58 35, 53 30 C 58 24, 55 16, 48 16 C 47 9, 38 8, 32 13 Z"/>
          <path d="M32 13 V50"/>
          <path d="M16 16 C 23 19, 24 25, 21 30"/>
          <path d="M11 30 C 18 31, 21 36, 19 43"/>
          <path d="M48 16 C 41 19, 40 25, 43 30"/>
          <path d="M53 30 C 46 31, 43 36, 45 43"/>
        </g>
      </svg>
      """
    if let data = svg.data(using: .utf8), let image = NSImage(data: data), image.isValid {
      image.size = NSSize(width: 18, height: 18)
      image.isTemplate = true
      return image
    }
    if let symbol = NSImage(systemSymbolName: "brain", accessibilityDescription: "Kaiba") {
      symbol.isTemplate = true
      return symbol
    }
    return NSImage(size: NSSize(width: 18, height: 18))
  }

  // MARK: - Server lifecycle

  private func startServer() {
    guard runtime == nil, !isBusy else {
      return
    }
    let configuration: KaibaServeConfiguration
    do {
      configuration = try Self.makeConfiguration()
    } catch {
      lastError = "\(error)"
      rebuildMenu()
      return
    }
    let runtime = KaibaServerRuntime(configuration)
    self.runtime = runtime
    isBusy = true
    lastError = nil
    rebuildMenu()
    Task {
      do {
        let info = try await runtime.start()
        self.startInfo = info
        self.lastError = nil
      } catch {
        self.runtime = nil
        self.startInfo = nil
        self.lastError = "\(error)"
      }
      self.isBusy = false
      self.rebuildMenu()
    }
  }

  private func stopServer() {
    guard let runtime, !isBusy else {
      return
    }
    isBusy = true
    rebuildMenu()
    Task {
      await runtime.stop()
      self.runtime = nil
      self.startInfo = nil
      self.isBusy = false
      self.rebuildMenu()
    }
  }

  /// Resolves the note root, config, and defaults the same way the CLI does, so
  /// the app and `kaiba serve` see one store. The app always runs authenticated
  /// on loopback — a resident background server must not be the thing that
  /// opens the store to the network.
  private static func makeConfiguration() throws -> KaibaServeConfiguration {
    let resolver = AppCommand(arguments: [])
    let environment = ProcessInfo.processInfo.environment
    let noteRoot = resolver.resolveNoteRoot(override: nil)
    let configPath = resolver.resolveConfigPath(override: nil)
    let configuration = try KaibaConfigurationLoader.load(
      at: configPath,
      required: !((environment["KAIBA_CONFIG_PATH"] ?? "").isEmpty)
    )
    return KaibaServeConfiguration(
      host: "127.0.0.1",
      port: 8787,
      noteRoot: noteRoot,
      configuration: configuration,
      webRoot: bundledWebRoot(),
      allowUnauthenticated: false,
      unauthenticatedActsAsAdmin: false,
      environment: environment
    )
  }

  /// The SPA shipped inside the app bundle at `Resources/web`, if present, so
  /// "Open web UI" lands on the reader rather than a bare API root. Absent in a
  /// bundle that ships only the server.
  private static func bundledWebRoot() -> String? {
    guard let resourceURL = Bundle.main.resourceURL else {
      return nil
    }
    let webRoot = resourceURL.appendingPathComponent("web", isDirectory: true)
    let index = webRoot.appendingPathComponent("index.html")
    return FileManager.default.fileExists(atPath: index.path) ? webRoot.path : nil
  }

  // MARK: - Menu actions

  @objc private func toggleServer() {
    if runtime == nil {
      startServer()
    } else {
      stopServer()
    }
  }

  @objc private func openWebUI() {
    guard let endpoint = startInfo?.endpoint, let url = URL(string: endpoint) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func copyRegistrationURL() {
    guard case let .authenticated(registrationURL, _)? = startInfo?.authMode else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(registrationURL, forType: .string)
  }

  @objc private func toggleLoginItem() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
      }
    } catch {
      lastError = "login item: \(error)"
    }
    rebuildMenu()
  }

  @objc private func quit() {
    // Stop the server before the process goes away so the port is released and
    // the sqlite handle closes cleanly.
    if let runtime {
      Task {
        await runtime.stop()
        NSApplication.shared.terminate(nil)
      }
    } else {
      NSApplication.shared.terminate(nil)
    }
  }

  // MARK: - Menu rendering

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(disabledItem(statusLine()))
    if let endpoint = startInfo?.endpoint {
      menu.addItem(disabledItem(endpoint))
    }
    if let lastError {
      menu.addItem(disabledItem("error: \(lastError)"))
    }
    menu.addItem(.separator())

    if startInfo != nil {
      menu.addItem(actionItem("Open web UI", #selector(openWebUI)))
      if case .authenticated = startInfo?.authMode {
        menu.addItem(actionItem("Copy registration URL", #selector(copyRegistrationURL)))
      }
    }

    let toggleTitle = runtime == nil ? "Start server" : "Stop server"
    let toggle = actionItem(toggleTitle, #selector(toggleServer))
    toggle.isEnabled = !isBusy
    menu.addItem(toggle)

    menu.addItem(.separator())
    let loginItem = actionItem("Start at login", #selector(toggleLoginItem))
    loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(loginItem)

    menu.addItem(.separator())
    menu.addItem(actionItem("Quit kaiba", #selector(quit)))
    statusItem?.menu = menu
  }

  private func statusLine() -> String {
    if isBusy {
      return runtime == nil ? "Server: stopping…" : "Server: starting…"
    }
    guard let startInfo else {
      return "Server: stopped"
    }
    if let port = startInfo.endpoint.split(separator: ":").last {
      return "Server: running :\(port)"
    }
    return "Server: running"
  }

  private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    item.target = self
    return item
  }
}
#endif
