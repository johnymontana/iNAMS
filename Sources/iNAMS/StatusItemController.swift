import AppKit
import Combine
import iNAMSKit

/// Owns the NSStatusItem and rebuilds its menu on every open so workspace
/// list, sandbox countdown, and pending-capture badge are always current.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let panelController: PanelController
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, panelController: PanelController) {
        self.appState = appState
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Text fallback keeps the item visible (non-zero width) even if the
        // symbol ever fails to resolve - an imageless, titleless variable-
        // length status item renders as nothing at all.
        let fallbackTitle: String
        if let button = statusItem.button {
            if let image = NSImage(
                systemSymbolName: "brain.head.profile",
                accessibilityDescription: "iNAMS"
            ) {
                button.image = image
                fallbackTitle = ""
            } else {
                fallbackTitle = "iN"
                button.title = fallbackTitle
            }
        } else {
            fallbackTitle = ""
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Badge the icon with the pending-capture count so a wedged sync is
        // visible without opening the menu.
        appState.$pendingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                let badge = count > 0 ? " \(count)" : ""
                self?.statusItem.button?.title = fallbackTitle + badge
            }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let capture = NSMenuItem(title: "Quick Capture", action: #selector(openCapture), keyEquivalent: "m")
        capture.keyEquivalentModifierMask = [.control, .option]
        capture.target = self
        menu.addItem(capture)

        let search = NSMenuItem(title: "Search Memories…", action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        menu.addItem(.separator())

        if appState.isSignedIn {
            addWorkspaceItems(to: menu)
            addStatusItems(to: menu)
            addMCPItems(to: menu)
            menu.addItem(.separator())
            let forget = NSMenuItem(title: "Forget API Key", action: #selector(forgetKey), keyEquivalent: "")
            forget.target = self
            menu.addItem(forget)
        } else {
            let connect = NSMenuItem(title: "Connect to NAMS…", action: #selector(connect), keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit iNAMS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addWorkspaceItems(to menu: NSMenu) {
        let workspaceMenu = NSMenu()
        for workspace in appState.workspaces {
            let item = NSMenuItem(
                title: workspace.name ?? workspace.id,
                action: #selector(selectWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == appState.selectedWorkspaceID ? .on : .off
            workspaceMenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        parent.submenu = workspaceMenu
        menu.addItem(parent)
    }

    private func addStatusItems(to menu: NSMenu) {
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if appState.pendingCount > 0 {
            let pending = NSMenuItem(
                title: "\(appState.pendingCount) capture(s) waiting to sync",
                action: nil, keyEquivalent: ""
            )
            pending.isEnabled = false
            menu.addItem(pending)

            let retry = NSMenuItem(title: "Retry Sync Now", action: #selector(retrySync), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
    }

    private func addMCPItems(to menu: NSMenu) {
        let mcpMenu = NSMenu()
        for target in [AppState.MCPTarget.claudeCode, .claudeDesktop] {
            let item = NSMenuItem(title: target.rawValue, action: #selector(setupMCP(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            mcpMenu.addItem(item)
        }
        let parent = NSMenuItem(title: "Connect an Agent (MCP)", action: nil, keyEquivalent: "")
        parent.submenu = mcpMenu
        menu.addItem(parent)
    }

    /// Countdown ticks locally off the last-polled expiry - no extra
    /// backend traffic to render the menu.
    private func statusLine() -> String {
        if appState.sandboxActive == false {
            return "Sandbox: not active"
        }
        guard let expiry = appState.sandboxExpiresAt else {
            return "Sandbox: status unknown"
        }
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return "Sandbox: expired" }
        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        if days > 0 { return "Sandbox expires in \(days)d \(hours)h" }
        let minutes = (Int(remaining) % 3600) / 60
        return "Sandbox expires in \(hours)h \(minutes)m"
    }

    // MARK: - Connect prompt

    /// Modal paste-an-Admin-key prompt; loops until a key validates or the
    /// user cancels. The field is deliberately a plain (visible) NSTextField:
    /// being able to eyeball a truncated paste beats masking a credential
    /// that was on the clipboard a second ago.
    func promptForKey() {
        Task { await runConnectPrompt() }
    }

    private func runConnectPrompt() async {
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Connect to NAMS"
            alert.informativeText = (problem.map { "\($0)\n\n" } ?? "")
                + "Paste an Admin API key. Create one in the NAMS dashboard under API Keys → “Manage workspaces”."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "nams_…"
            alert.accessoryView = field
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try await appState.connect(rawKey: field.stringValue)
                return
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: - Actions

    @objc private func openCapture() { panelController.show(mode: .capture) }
    @objc private func openSearch() { panelController.show(mode: .search) }
    @objc private func retrySync() { Task { await appState.drainNow() } }
    @objc private func forgetKey() { appState.forgetKey() }
    @objc private func connect() { promptForKey() }

    @objc private func selectWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        appState.selectedWorkspaceID = id
        Task { await appState.refreshStatus() }
    }

    @objc private func setupMCP(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let target = AppState.MCPTarget(rawValue: raw) else { return }
        Task {
            do {
                let message = try await appState.setupMCP(target)
                showAlert(title: "\(target.rawValue) connected", message: message, style: .informational)
            } catch {
                showAlert(title: "MCP setup failed", message: error.localizedDescription, style: .warning)
            }
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
